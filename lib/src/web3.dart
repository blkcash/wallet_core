library web3;

import 'dart:async';
import 'dart:math';

import 'package:http/http.dart';
import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:hex/hex.dart';
import 'package:web3dart/crypto.dart';
import 'package:web3dart/web3dart.dart';
import 'package:resource/resource.dart';

const String RPC_URL = 'https://rpc.fusenet.io';
const num NETWORK_ID = 122;

const String DEFAULT_COMMUNITY_CONTRACT_ADDRESS =
    '0xbA01716EAD7989a00cC3b2AE6802b54eaF40fb72';

const String NATIVE_TOKEN_ADDRESS =
    '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE'; // For sending native (ETH/FUSE) using TransferManager

const String COMMUNITY_MANAGER_CONTRACT_ADDRESS =
    '0x306BB3f40BEa3710cAc4BD9F1Ef052aD999d7233';
const String TRANSFER_MANAGER_CONTRACT_ADDRESS =
    '0xBbE1EcEE01bBa382088E243624aE69C4D7F378A8';

class Web3 {
  Web3Client _client;
  Future<bool> _approveCb;
  Credentials _credentials;
  num _networkId;

  Web3(Future<bool> approveCb(), {String url, num networkId}) {
    _client = new Web3Client(url ?? RPC_URL, new Client());
    _approveCb = approveCb();
    _networkId = networkId ?? NETWORK_ID;
  }

  String generateMnemonic() {
    return bip39.generateMnemonic();
  }

  String privateKeyFromMnemonic(String mnemonic) {
    String seed = bip39.mnemonicToSeedHex(mnemonic);
    bip32.BIP32 root = bip32.BIP32.fromSeed(HEX.decode(seed));
    bip32.BIP32 child = root.derivePath("m/44'/60'/0'/0/0");
    String privateKey = HEX.encode(child.privateKey);
    return privateKey;
  }

  Future<void> setCredentials(String privateKey) async {
    _credentials = await _client.credentialsFromPrivateKey(privateKey);
  }

  Future<String> getAddress() async {
    return (await _credentials.extractAddress()).toString();
  }

  Future<String> _sendTransactionAndWaitForReceipt(
      Transaction transaction) async {
    print('sendTransactionAndWaitForReceipt');
    String txHash = await _client.sendTransaction(_credentials, transaction,
        chainId: _networkId);
    TransactionReceipt receipt;
    try {
      receipt = await _client.getTransactionReceipt(txHash);
    } catch (err) {
      print('could not get $txHash receipt, try again');
    }
    num delay = 1;
    num retries = 5;
    while (receipt == null) {
      print('waiting for receipt');
      await Future.delayed(new Duration(seconds: delay));
      delay *= 2;
      retries--;
      if (retries == 0) {
        throw 'transaction $txHash not mined...';
      }
      try {
        receipt = await _client.getTransactionReceipt(txHash);
      } catch (err) {
        print('could not get $txHash receipt, try again');
      }
    }
    return txHash;
  }

  Future<EtherAmount> getBalance({String address}) async {
    EthereumAddress a;
    if (address != null && address != "") {
      a = EthereumAddress.fromHex(address);
    } else {
      a = EthereumAddress.fromHex(await getAddress());
    }
    return await _client.getBalance(a);
  }

  Future<String> transfer(String receiverAddress, num amountInWei) async {
    print('transfer --> receiver: $receiverAddress, amountInWei: $amountInWei');

    bool isApproved = await _approveCb;
    if (!isApproved) {
      throw 'transaction not approved';
    }

    EthereumAddress receiver = EthereumAddress.fromHex(receiverAddress);
    EtherAmount amount =
        EtherAmount.fromUnitAndValue(EtherUnit.wei, BigInt.from(amountInWei));

    String txHash = await _sendTransactionAndWaitForReceipt(
        Transaction(to: receiver, value: amount));
    print('transction $txHash successful');
    return txHash;
  }

  Future<DeployedContract> _contract(
      String contractName, String contractAddress) async {
    Resource abiFile =
        new Resource("package:wallet_core/abis/$contractName.json");
    String abi = await abiFile.readAsString();
    DeployedContract contract = DeployedContract(
        ContractAbi.fromJson(abi, contractName),
        EthereumAddress.fromHex(contractAddress));
    return contract;
  }

  Future<List<dynamic>> _readFromContract(String contractName,
      String contractAddress, String functionName, List<dynamic> params) async {
    DeployedContract contract = await _contract(contractName, contractAddress);
    return await _client.call(
        contract: contract,
        function: contract.function(functionName),
        params: params);
  }

  Future<String> _callContract(String contractName, String contractAddress,
      String functionName, List<dynamic> params) async {
    bool isApproved = await _approveCb;
    if (!isApproved) {
      throw 'transaction not approved';
    }
    DeployedContract contract = await _contract(contractName, contractAddress);
    Transaction tx = Transaction.callContract(
        contract: contract,
        function: contract.function(functionName),
        parameters: params);
    return await _sendTransactionAndWaitForReceipt(tx);
  }

  Future<dynamic> getTokenDetails(String tokenAddress) async {
    return {
      "name": (await _readFromContract('BasicToken', tokenAddress, 'name', []))
          .first,
      "symbol":
          (await _readFromContract('BasicToken', tokenAddress, 'symbol', []))
              .first,
      "decimals":
          (await _readFromContract('BasicToken', tokenAddress, 'decimals', []))
              .first
    };
  }

  Future<dynamic> getTokenBalance(String tokenAddress, {String address}) async {
    List<dynamic> params = [];
    if (address != null && address != "") {
      params = [EthereumAddress.fromHex(address)];
    } else {
      params = [EthereumAddress.fromHex(await getAddress())];
    }
    return (await _readFromContract(
            'BasicToken', tokenAddress, 'balanceOf', params))
        .first;
  }

  Future<String> tokenTransfer(
      String tokenAddress, String receiverAddress, num tokensAmount) async {
    EthereumAddress receiver = EthereumAddress.fromHex(receiverAddress);
    dynamic tokenDetails = await getTokenDetails(tokenAddress);
    num tokenDecimals = int.parse(tokenDetails["decimals"].toString());
    BigInt amount = BigInt.from(tokensAmount * pow(10, tokenDecimals));
    return await _callContract(
        'BasicToken', tokenAddress, 'transfer', [receiver, amount]);
  }

  Future<String> joinCommunity(String walletAddress,
      {String communityAddress}) async {
    EthereumAddress wallet = EthereumAddress.fromHex(walletAddress);
    EthereumAddress community = EthereumAddress.fromHex(
        communityAddress ?? DEFAULT_COMMUNITY_CONTRACT_ADDRESS);
    return await _callContract(
        'CommunityManager',
        COMMUNITY_MANAGER_CONTRACT_ADDRESS,
        'joinCommunity',
        [wallet, community]);
  }

  Future<EtherAmount> cashGetBalance(String walletAddress) async {
    return await getBalance(address: walletAddress);
  }

  Future<String> cashTransfer(
      String walletAddress, String receiverAddress, num amountInWei) async {
    EthereumAddress wallet = EthereumAddress.fromHex(walletAddress);
    EthereumAddress token = EthereumAddress.fromHex(NATIVE_TOKEN_ADDRESS);
    EthereumAddress receiver = EthereumAddress.fromHex(receiverAddress);
    BigInt amount = BigInt.from(amountInWei);
    return await _callContract(
        'TransferManager',
        TRANSFER_MANAGER_CONTRACT_ADDRESS,
        'transferToken',
        [wallet, token, receiver, amount, hexToBytes('0x')]);
  }

  Future<String> cashTokenTransfer(String walletAddress, String tokenAddress,
      String receiverAddress, num tokensAmount) async {
    EthereumAddress wallet = EthereumAddress.fromHex(walletAddress);
    EthereumAddress token = EthereumAddress.fromHex(tokenAddress);
    EthereumAddress receiver = EthereumAddress.fromHex(receiverAddress);
    dynamic tokenDetails = await getTokenDetails(tokenAddress);
    num tokenDecimals = int.parse(tokenDetails["decimals"].toString());
    BigInt amount = BigInt.from(tokensAmount * pow(10, tokenDecimals));
    return await _callContract(
        'TransferManager',
        TRANSFER_MANAGER_CONTRACT_ADDRESS,
        'transferToken',
        [wallet, token, receiver, amount, hexToBytes('0x')]);
  }

  Future<dynamic> cashGetTokenBalance(
      String walletAddress, String tokenAddress) async {
    return getTokenBalance(tokenAddress, address: walletAddress);
  }
}
