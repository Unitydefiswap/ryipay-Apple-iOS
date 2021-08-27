// Copyright © 2021 Stormbird PTE. LTD.

import Foundation
import Alamofire
import PromiseKit

enum ContractData {
    case name(String)
    case symbol(String)
    case balance(balance: [String], tokenType: TokenType)
    case decimals(UInt8)
    case nonFungibleTokenComplete(name: String, symbol: String, balance: [String], tokenType: TokenType)
    case fungibleTokenComplete(name: String, symbol: String, decimals: UInt8)
    case delegateTokenComplete
    case failed(networkReachable: Bool?)
}

class ContractDataDetector {
    private let address: AlphaWallet.Address
    private let storage: TokensDataStore
    private let assetDefinitionStore: AssetDefinitionStore
    private let namePromise: Promise<String>
    private let symbolPromise: Promise<String>
    private let tokenTypePromise: Promise<TokenType>
    private let (nonFungibleBalancePromise, nonFungibleBalanceSeal) = Promise<[String]>.pending()
    private let (decimalsPromise, decimalsSeal) = Promise<UInt8>.pending()
    private var failed = false
    private var completion: ((ContractData) -> Void)?

    init(address: AlphaWallet.Address, storage: TokensDataStore, assetDefinitionStore: AssetDefinitionStore) {
        self.address = address
        self.storage = storage
        self.assetDefinitionStore = assetDefinitionStore
        namePromise = storage.getContractName(for: address)
        symbolPromise = storage.getContractSymbol(for: address)
        tokenTypePromise = storage.getTokenType(for: address)
    }

    /// Failure to obtain contract data may be due to no-connectivity. So we should check .failed(networkReachable: Bool)
    //Have to use strong self in promises below, otherwise `self` will be destroyed before fetching completes
    func fetch(completion: @escaping (ContractData) -> Void) {
        self.completion = completion

        assetDefinitionStore.fetchXML(forContract: address)

        firstly {
            namePromise
        }.done { name in
            self.completionOfPartialData(.name(name))
        }.catch { error in
            self.callCompletionFailed()
            //We consider name and symbol and empty string because NFTs (ERC721 and ERC1155) don't have to implement `name` and `symbol`. Eg. ENS/721 (0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85) and Enjin/1155 (0xfaafdc07907ff5120a76b34b731b278c38d6043c)
            self.completionOfPartialData(.name(""))
        }

        firstly {
            symbolPromise
        }.done { symbol in
            self.completionOfPartialData(.symbol(symbol))
        }.catch { error in
            self.callCompletionFailed()
            //We consider name and symbol and empty string because NFTs (ERC721 and ERC1155) don't have to implement `name` and `symbol`. Eg. ENS/721 (0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85) and Enjin/1155 (0xfaafdc07907ff5120a76b34b731b278c38d6043c)
            self.completionOfPartialData(.symbol(""))
        }

        firstly {
            tokenTypePromise
        }.done { tokenType in
            switch tokenType {
            case .erc875:
                self.storage.getERC875Balance(for: self.address) { result in
                    switch result {
                    case .success(let balance):
                        self.nonFungibleBalanceSeal.fulfill(balance)
                        self.completionOfPartialData(.balance(balance: balance, tokenType: .erc875))
                    case .failure(let error):
                        self.nonFungibleBalanceSeal.reject(error)
                        self.callCompletionFailed()
                    }
                }
            case .erc721:
                self.storage.getERC721Balance(for: self.address) { result in
                    switch result {
                    case .success(let balance):
                        self.nonFungibleBalanceSeal.fulfill(balance)
                        self.completionOfPartialData(.balance(balance: balance, tokenType: .erc721))
                    case .failure(let error):
                        self.nonFungibleBalanceSeal.reject(error)
                        self.callCompletionFailed()
                    }
                }
            case .erc721ForTickets:
                self.storage.getERC721ForTicketsBalance(for: self.address) { result in
                    switch result {
                    case .success(let balance):
                        self.nonFungibleBalanceSeal.fulfill(balance)
                        self.completionOfPartialData(.balance(balance: balance, tokenType: .erc721ForTickets))
                    case .failure(let error):
                        self.nonFungibleBalanceSeal.reject(error)
                        self.callCompletionFailed()
                    }
                }
            case .erc20:
                self.storage.getDecimals(for: self.address) { result in
                    switch result {
                    case .success(let decimal):
                        self.decimalsSeal.fulfill(decimal)
                        self.completionOfPartialData(.decimals(decimal))
                    case .failure(let error):
                        self.decimalsSeal.reject(error)
                        self.callCompletionFailed()
                    }
                }
            case .nativeCryptocurrency:
                break
            }
        }.cauterize()
    }

    private func completionOfPartialData(_ data: ContractData) -> Void {
        completion?(data)
        callCompletionOnAllData()
    }

    private func callCompletionFailed() {
        guard !failed else {
            return
        }
        failed = true
        //TODO maybe better to share an instance of the reachability manager
        completion?(.failed(networkReachable: NetworkReachabilityManager()?.isReachable))
    }

    private func callCompletionAsDelegateTokenOrNot() {
        assert(symbolPromise.value != nil && symbolPromise.value?.isEmpty == true)
        //Must check because we also get an empty symbol (and name) if there's no connectivity
        //TODO maybe better to share an instance of the reachability manager
        if let reachabilityManager = NetworkReachabilityManager(), reachabilityManager.isReachable {
            completion?(.delegateTokenComplete)
        } else {
            callCompletionFailed()
        }
    }

    private func callCompletionOnAllData() {
        if namePromise.isResolved, symbolPromise.isResolved, let tokenType = tokenTypePromise.value {
            switch tokenType {
            case .erc875, .erc721, .erc721ForTickets:
                if let nonFungibleBalance = nonFungibleBalancePromise.value {
                    let name = namePromise.value
                    let symbol = symbolPromise.value
                    completion?(.nonFungibleTokenComplete(name: name ?? "", symbol: symbol ?? "", balance: nonFungibleBalance, tokenType: tokenType))
                }
            case .nativeCryptocurrency, .erc20:
                if let name = namePromise.value, let symbol = symbolPromise.value, let decimals = decimalsPromise.value {
                    if symbol.isEmpty {
                        callCompletionAsDelegateTokenOrNot()
                    } else {
                        completion?(.fungibleTokenComplete(name: name, symbol: symbol, decimals: decimals))
                    }
                }
            }
        } else if let name = namePromise.value, let symbol = symbolPromise.value, let decimals = decimalsPromise.value {
            if symbol.isEmpty {
                callCompletionAsDelegateTokenOrNot()
            } else {
                completion?(.fungibleTokenComplete(name: name, symbol: symbol, decimals: decimals))
            }
        }
    }
}