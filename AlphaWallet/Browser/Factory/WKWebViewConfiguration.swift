// Copyright DApps Platform Inc. All rights reserved.

import Foundation
import WebKit
import JavaScriptCore

enum WebViewType {
    case dappBrowser
    case tokenScriptRenderer
}

extension WKWebViewConfiguration {

    static func make(forType type: WebViewType, server server: RPCServer, address: AlphaWallet.Address, in messageHandler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let webViewConfig = WKWebViewConfiguration()
        var js = ""

        switch type {
        case .dappBrowser:
            guard
                    let bundlePath = Bundle.main.path(forResource: "AlphaWalletWeb3Provider", ofType: "bundle"),
                    let bundle = Bundle(path: bundlePath) else { return webViewConfig }

            if let filepath = bundle.path(forResource: "AlphaWallet-min", ofType: "js") {
                do {
                    js += try String(contentsOfFile: filepath)
                } catch { }
            }
            js += javaScriptForDappBrowser(server: server, address: address)
            break
        case .tokenScriptRenderer:
            js += javaScriptForTokenScriptRenderer(server: server, address: address)
            js += """
                  \n
                  web3.tokens = {
                      data: {
                          currentInstance: {
                          },
                      },
                      dataChanged: (tokens) => {
                        console.log(\"web3.tokens.data changed. You should assign a function to `web3.tokens.dataChanged` to monitor for changes like this:\\n    `web3.tokens.dataChanged = (oldTokens, updatedTokens) => { //do something }`\")
                      }
                  }
                  """
        }
        let userScript = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        webViewConfig.userContentController.addUserScript(userScript)

        switch type {
        case .dappBrowser:
            break
        case .tokenScriptRenderer:
            //TODO enable content blocking rules to support whitelisting
//            let json = contentBlockingRulesJson()
//            if #available(iOS 11.0, *) {
//                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ContentBlockingRules", encodedContentRuleList: json) { (contentRuleList, error) in
//                    guard let contentRuleList = contentRuleList,
//                          error == nil else {
//                        return
//                    }
//                    webViewConfig.userContentController.add(contentRuleList)
//                }
//            }
            if #available(iOS 11.0, *) {
                webViewConfig.setURLSchemeHandler(webViewConfig, forURLScheme: "tokenscript-resource")
            }
        }

        webViewConfig.userContentController.add(messageHandler, name: Method.signTransaction.rawValue)
        webViewConfig.userContentController.add(messageHandler, name: Method.signPersonalMessage.rawValue)
        webViewConfig.userContentController.add(messageHandler, name: Method.signMessage.rawValue)
        webViewConfig.userContentController.add(messageHandler, name: Method.signTypedMessage.rawValue)
        return webViewConfig
    }

    fileprivate static func javaScriptForDappBrowser(server server: RPCServer, address: AlphaWallet.Address) -> String {
        return """
               const addressHex = "\(address.eip55String)"
               const rpcURL = "\(server.rpcURL.absoluteString)"
               const chainID = "\(server.chainID)"

               function executeCallback (id, error, value) {
                   AlphaWallet.executeCallback(id, error, value)
               }

               AlphaWallet.init(rpcURL, {
                   getAccounts: function (cb) { cb(null, [addressHex]) },
                   processTransaction: function (tx, cb){
                       console.log('signing a transaction', tx)
                       const { id = 8888 } = tx
                       AlphaWallet.addCallback(id, cb)
                       webkit.messageHandlers.signTransaction.postMessage({"name": "signTransaction", "object":     tx, id: id})
                   },
                   signMessage: function (msgParams, cb) {
                       const { data } = msgParams
                       const { id = 8888 } = msgParams
                       console.log("signing a message", msgParams)
                       AlphaWallet.addCallback(id, cb)
                       webkit.messageHandlers.signMessage.postMessage({"name": "signMessage", "object": { data }, id:    id} )
                   },
                   signPersonalMessage: function (msgParams, cb) {
                       const { data } = msgParams
                       const { id = 8888 } = msgParams
                       console.log("signing a personal message", msgParams)
                       AlphaWallet.addCallback(id, cb)
                       webkit.messageHandlers.signPersonalMessage.postMessage({"name": "signPersonalMessage", "object":  { data }, id: id})
                   },
                   signTypedMessage: function (msgParams, cb) {
                       const { data } = msgParams
                       const { id = 8888 } = msgParams
                       console.log("signing a typed message", msgParams)
                       AlphaWallet.addCallback(id, cb)
                       webkit.messageHandlers.signTypedMessage.postMessage({"name": "signTypedMessage", "object":     { data }, id: id})
                   },
                   enable: function() {
                      return new Promise(function(resolve, reject) {
                          //send back the coinbase account as an array of one
                          resolve([addressHex])
                      })
                   },
                   send: function(payload) {
                      let response = {
                        jsonrpc: "2.0",
                        id: payload.id
                      };
                      switch(payload.method) {
                        case "eth_accounts":
                          response.result = this.eth_accounts();
                          break;
                        case "eth_coinbase":
                          response.result = this.eth_coinbase();
                          break;
                        case "net_version":
                          response.result = this.net_version();
                          break;
                        case "eth_uninstallFilter":
                          this.sendAsync(payload, (error) => {
                            if (error) {
                              console.log(`<== uninstallFilter ${error}`);
                            }
                          });
                          response.result = true;
                          break;
                        default:
                          throw new Error(`AlphaWallet does not support calling ${payload.method} synchronously without a callback. Please provide a callback parameter to call ${payload.method} asynchronously.`);
                      }
                      return response;
                    },

                    sendAsync: function(payload, callback) {
                      if (Array.isArray(payload)) {
                        Promise.all(payload.map(this._sendAsync.bind(this)))
                        .then(data => callback(null, data))
                        .catch(error => callback(error, null));
                      } else {
                        this._sendAsync(payload)
                        .then(data => callback(null, data))
                        .catch(error => callback(error, null));
                      }
                    },

                    _sendAsync: function(payload) {
                      this.idMapping.tryIntifyId(payload);
                      return new Promise((resolve, reject) => {
                        if (!payload.id) {
                          payload.id = Utils.genId();
                        }
                        this.callbacks.set(payload.id, (error, data) => {
                          if (error) {
                            reject(error);
                          } else {
                            resolve(data);
                          }
                        });

                        switch(payload.method) {
                          case "eth_accounts":
                            return this.sendResponse(payload.id, this.eth_accounts());
                          case "eth_coinbase":
                            return this.sendResponse(payload.id, this.eth_coinbase());
                          case "net_version":
                            return this.sendResponse(payload.id, this.net_version());
                          case "eth_sign":
                            return this.eth_sign(payload);
                          case "personal_sign":
                            return this.personal_sign(payload);
                          case "personal_ecRecover":
                            return this.personal_ecRecover(payload);
                          case "eth_signTypedData":
                          case "eth_signTypedData_v3":
                            return this.eth_signTypedData(payload);
                          case "eth_sendTransaction":
                            return this.eth_sendTransaction(payload);
                          case "eth_requestAccounts":
                            return this.eth_requestAccounts(payload);
                          case "eth_newFilter":
                            return this.eth_newFilter(payload);
                          case "eth_newBlockFilter":
                            return this.eth_newBlockFilter(payload);
                          case "eth_newPendingTransactionFilter":
                            return this.eth_newPendingTransactionFilter(payload);
                          case "eth_uninstallFilter":
                            return this.eth_uninstallFilter(payload);
                          case "eth_getFilterChanges":
                            return this.eth_getFilterChanges(payload);
                          case "eth_getFilterLogs":
                            return this.eth_getFilterLogs(payload);
                          default:
                            this.callbacks.delete(payload.id);
                            return this.rpc.call(payload).then(resolve).catch(reject);
                        }
                      });
                    },

                    eth_accounts: function() {
                      return this.address ? [this.address] : [];
                    },

                    eth_coinbase: function() {
                      return this.address;
                    },

                    net_version: function() {
                      return this.chainId.toString(10) || null;
                    },

                    eth_sign: function(payload) {
                      this.postMessage("signMessage", payload.id, {data: payload.params[1]});
                    },

                    personal_sign: function(payload) {
                      this.postMessage("signPersonalMessage", payload.id, {data: payload.params[0]});
                    },

                    personal_ecRecover: function(payload) {
                      this.postMessage("ecRecover", payload.id, {signature: payload.params[1], message: payload.params[0]});
                    },

                    eth_signTypedData: function(payload) {
                      this.postMessage("signTypedMessage", payload.id, {data: payload.params[1]});
                    },

                    eth_sendTransaction: function(payload) {
                      this.postMessage("signTransaction", payload.id, payload.params[0]);
                    },

                    eth_requestAccounts: function(payload) {
                      this.postMessage("requestAccounts", payload.id, {});
                    },

                    eth_newFilter: function(payload) {
                      this.filterMgr.newFilter(payload)
                      .then(filterId => this.sendResponse(payload.id, filterId))
                      .catch(error => this.sendError(payload.id, error));
                    },

                    eth_newBlockFilter: function(payload) {
                      this.filterMgr.newBlockFilter()
                      .then(filterId => this.sendResponse(payload.id, filterId))
                      .catch(error => this.sendError(payload.id, error));
                    },

                    eth_newPendingTransactionFilter: function(payload) {
                      this.filterMgr.newPendingTransactionFilter()
                      .then(filterId => this.sendResponse(payload.id, filterId))
                      .catch(error => this.sendError(payload.id, error));
                    },

                    eth_uninstallFilter: function(payload) {
                      this.filterMgr.uninstallFilter(payload.params[0])
                      .then(filterId => this.sendResponse(payload.id, filterId))
                      .catch(error => this.sendError(payload.id, error));
                    },

                    eth_getFilterChanges: function(payload) {
                      this.filterMgr.getFilterChanges(payload.params[0])
                      .then(data => this.sendResponse(payload.id, data))
                      .catch(error => this.sendError(payload.id, error));
                    },

                    eth_getFilterLogs: function(payload) {
                      this.filterMgr.getFilterLogs(payload.params[0])
                      .then(data => this.sendResponse(payload.id, data))
                      .catch(error => this.sendError(payload.id, error));
                    },

                    postMessage: function(handler, id, data) {
                      if (this.ready || handler === "requestAccounts") {
                        window.webkit.messageHandlers[handler].postMessage({
                          "name": handler,
                          "object": data,
                          "id": id
                        });
                      } else {
                        // don't forget to verify in the app
                        this.sendError(id, new Error("provider is not ready"));
                      }
                    },

                    sendResponse: function(id, result) {
                      let originId = this.idMapping.tryPopId(id) || id;
                      let callback = this.callbacks.get(id);
                      let data = {jsonrpc: "2.0", id: originId};
                      if (typeof result === "object" && result.jsonrpc && result.result) {
                        data.result = result.result;
                      } else {
                        data.result = result;
                      }
                      if (callback) {
                        callback(null, data);
                        this.callbacks.delete(id);
                      }
                    },

                    sendError: function(id, error) {
                      console.log(`<== ${id} sendError ${error}`);
                      let callback = this.callbacks.get(id);
                      if (callback) {
                        callback(error instanceof Error ? error : new Error(error), null);
                        this.callbacks.delete(id);
                      }
                    }
               }, {
                   address: addressHex,
                   networkVersion: chainID
               })

               web3.setProvider = function () {
                   console.debug('AlphaWallet Wallet - overrode web3.setProvider')
               }

               web3.eth.defaultAccount = addressHex

               web3.version.getNetwork = function(cb) {
                   cb(null, chainID)
               }

              web3.eth.getCoinbase = function(cb) {
               return cb(null, addressHex)
             }
             window.ethereum = web3.currentProvider
             """
    }

    fileprivate static func javaScriptForTokenScriptRenderer(server server: RPCServer, address: AlphaWallet.Address) -> String {
        return """
               window.web3CallBacks = {}

               function executeCallback (id, error, value) {
                   window.web3CallBacks[id](error, value)
                   delete window.web3CallBacks[id]
               }

               web3 = {
                 personal: {
                   sign: function (msgParams, cb) {
                     const { data } = msgParams
                     const { id = 8888 } = msgParams
                     window.web3CallBacks[id] = cb
                     webkit.messageHandlers.signPersonalMessage.postMessage({"name": "signPersonalMessage", "object":  { data }, id: id})
                   }
                 }
               }
               """
    }

    fileprivate static func contentBlockingRulesJson() -> String {
        //TODO read from TokenScript, when it's designed and available
        let whiteListedUrls = [
            "https://unpkg.com/",
            "^tokenscript-resource://",
            "^http://stormbird.duckdns.org:8080/api/getChallenge$",
            "^http://stormbird.duckdns.org:8080/api/checkSignature"
        ]
        //Blocks everything, except the whitelisted URL patterns
        var json = """
                   [
                       {
                           "trigger": {
                               "url-filter": ".*"
                           },
                           "action": {
                               "type": "block"
                           }
                       }
                   """
        for each in whiteListedUrls {
            json += """
                    ,
                    {
                        "trigger": {
                            "url-filter": "\(each)"
                        },
                        "action": {
                            "type": "ignore-previous-rules"
                        }
                    }
                    """
        }
        json += "]"
        return json
    }
}

@available(iOS 11.0, *)
extension WKWebViewConfiguration: WKURLSchemeHandler {
    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        if let path = urlSchemeTask.request.url?.path {
            if let fileExtension = urlSchemeTask.request.url?.pathExtension, fileExtension == "otf", let nameWithoutExtension = urlSchemeTask.request.url?.deletingPathExtension().lastPathComponent {
                //TODO maybe good to fail with didFailWithError(error:)
                guard let url = Bundle.main.url(forResource: nameWithoutExtension, withExtension: fileExtension) else { return }
                guard let data = try? Data(contentsOf: url) else { return }
                //mimeType doesn't matter. Blocking is done based on how browser intends to use it
                let response = URLResponse(url: urlSchemeTask.request.url!, mimeType: "font/opentype", expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                return
            }
        }
        //TODO maybe good to fail:
        //urlSchemeTask.didFailWithError(error:)
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        //Do nothing
    }
}
