//
//  RedditAPI.swift
//  winston
//
//  Created by Igor Marcossi on 24/06/23.
//

import Foundation
import KeychainAccess
import Alamofire
import SwiftUI
import Defaults
import Combine

class RedditAPI: ObservableObject {
  static let shared = RedditAPI()
  static let winstonAPIBase = "https://winston.lo.cafe/api"
  static let redditApiURLBase = "https://oauth.reddit.com"
  static let redditWWWApiURLBase = "https://www.reddit.com"
  static let appRedirectURI: String = "https://app.winston.cafe/auth-success"
  
  var lastAuthState: String?
  @Published var me: User?
  /// Why the last feed page failed to load, shown in the feed instead of an endless spinner.
  @Published var lastFeedError: String?
  
  func setFeedError(_ error: String?) async {
    await MainActor.run {
      if self.lastFeedError != error { self.lastFeedError = error }
    }
  }
  
  // This is a replacement for getRequestHeader. We need to replace every instance of the former by this one
  func fetchRequestHeaders(force: Bool = false, includeAuth: Bool = true, altCredential: RedditCredential? = nil, saveToken: Bool = true) async -> HTTPHeaders? {
    var headers: HTTPHeaders = [
      "User-Agent": Defaults[.GeneralDefSettings].redditAPIUserAgent
    ]
    if includeAuth {
      if let selectedCredential = altCredential ?? RedditCredentialsManager.shared.selectedCredential, let accessToken = await selectedCredential.getUpToDateToken(forceRenew: force, saveToken: saveToken) {
        headers["Authorization"] = "Bearer \(accessToken.token)"
      } else {
        return nil
      }
    }
    
    //    for (protectionSpace, credentials) in URLCredentialStorage.shared.allCredentials {
    //        for (_, credential) in credentials {
//          // Even though the values are not optionals, it seems to crash at some points if you don't do the check
//          if URLCredentialStorage.shared != nil && credential != nil && protectionSpace != nil {
//            URLCredentialStorage.shared.remove(credential, for: protectionSpace)
//          }
//        }
//    }
    HTTPCookieStorage.shared.cookies?.forEach(HTTPCookieStorage.shared.deleteCookie)    
    
    return headers
  }
  
  private let reqAttempts = 2
  
  private let reqModifier: Session.RequestModifier = { urlReq in
    urlReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
  }
  
  func doRequest<D: Decodable, P: Encodable>(_ url: String, authenticated: Bool = true, method: HTTPMethod, params: P? = nil, paramsLocation: URLEncodedFormParameterEncoder.Destination = .httpBody, decodable: D.Type, altCredential: RedditCredential? = nil, attempt: Int = 0, saveToken: Bool = true) async -> Result<D, AFError> {
    return await self._doRequest(authenticated: authenticated, altCredential: altCredential, saveToken: saveToken) { headers in
      let req = AF.request(url, method: method, parameters: params, encoder: URLEncodedFormParameterEncoder(destination: paramsLocation), headers: headers, requestModifier: reqModifier).validate()
      return await req.serializingDecodable(decodable).response.result
    }
  }
  
  func doRequest<D: Decodable>(_ url: String, authenticated: Bool = true, method: HTTPMethod, decodable: D.Type, altCredential: RedditCredential? = nil, attempt: Int = 0, saveToken: Bool = true) async -> Result<D, AFError> {
    return await self._doRequest(authenticated: authenticated, altCredential: altCredential, saveToken: saveToken) { headers in
      let req = AF.request(url, method: method, headers: headers, requestModifier: reqModifier).validate()
      return await req.serializingDecodable(decodable).response.result
    }
  }
  
  func doRequest<P: Encodable>(_ url: String, authenticated: Bool = true, method: HTTPMethod, params: P, paramsLocation: URLEncodedFormParameterEncoder.Destination = .httpBody, altCredential: RedditCredential? = nil, attempt: Int = 0, saveToken: Bool = true) async -> Result<String, AFError> {
    return await self._doRequest(authenticated: authenticated, altCredential: altCredential, saveToken: saveToken) { headers in
      let req = AF.request(url, method: method, parameters: params, encoder: URLEncodedFormParameterEncoder(destination: paramsLocation), headers: headers, requestModifier: reqModifier).validate()
      return await req.serializingString().result
    }
  }
  
  func doRequest(_ url: String, authenticated: Bool = true, method: HTTPMethod, paramsLocation: URLEncodedFormParameterEncoder.Destination = .httpBody, altCredential: RedditCredential? = nil, attempt: Int = 0, saveToken: Bool = true) async -> Result<String, AFError> {
    return await self._doRequest(authenticated: authenticated, altCredential: altCredential, saveToken: saveToken) { headers in
      let req = AF.request(url, method: method, headers: headers).validate()
      return await req.serializingString().result
    }
  }
  
  func _doRequest<D: Decodable>(attempt: Int = 0, forceAuth: Bool = false, authenticated: Bool = true, altCredential: RedditCredential? = nil, saveToken: Bool = true, req: (HTTPHeaders) async -> Result<D, AFError>) async -> Result<D, AFError> {
    guard let headers = await fetchRequestHeaders(force: forceAuth, includeAuth: authenticated, altCredential: altCredential, saveToken: saveToken) else { return .failure(.serverTrustEvaluationFailed(reason: .noPublicKeysFound)) }

    let result = await req(headers)
    if case .failure(let error) = result {
      print(error)
      if attempt < (authenticated ? 3 : 2) && Self.shouldRetry(error, authenticated: authenticated) {
        // An expired token gets one immediate retry with a fresh token. Anything else
        // (rate limit, server error, dropped connection) waits a little before trying
        // again, so retries don't burn through Reddit's rate limit.
        let isAuthError = error.responseCode == 401
        if !isAuthError {
          try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (1 << attempt)))
        }
        return await self._doRequest(attempt: attempt + 1, forceAuth: authenticated && isAuthError, authenticated: authenticated, altCredential: altCredential, saveToken: saveToken, req: req)
      }
    }
    return result
  }
  
  /// Decoding errors and most 4xx responses fail the same way every time, so retrying
  /// them only adds load and delay.
  static func shouldRetry(_ error: AFError, authenticated: Bool) -> Bool {
    if error.isExplicitlyCancelledError || error.isResponseSerializationError { return false }
    if let code = error.responseCode {
      if code == 401 { return authenticated }
      return code == 408 || code == 429 || code >= 500
    }
    return true
  }
  
  func injectFirstAccessTokenInto(_ credential: inout RedditCredential, authCode: String) async -> Bool {
    if !credential.apiAppID.isEmpty && !credential.apiAppSecret.isEmpty {
      let headers = await fetchRequestHeaders(includeAuth: false)
      var code = authCode
      if code.hasSuffix("#_") {
        code = "\(code.dropLast(2))"
      }
      let payload = GetAccessTokenPayload(code: authCode)
      let response = await AF.request(
        "\(RedditAPI.redditWWWApiURLBase)/api/v1/access_token",
        method: .post,
        parameters: payload,
        encoder: URLEncodedFormParameterEncoder(destination: .httpBody),
        headers: headers
      )
        .authenticate(username: credential.apiAppID, password: credential.apiAppSecret, persistence: .none)
        .serializingDecodable(GetAccessTokenResponse.self).response
      switch response.result {
      case .success(let data):
        let newAcessToken = RedditCredential.AccessToken(token: data.access_token, expiration: data.expires_in, lastRefresh: Date())
        credential.refreshToken = data.refresh_token
        credential.accessToken = newAcessToken
        if let meData = await self.fetchMe(force: true, altCredential: credential, saveToken: false) {
          credential.userName = meData.name
          if let avatar = (meData.subreddit?.icon_img ?? meData.icon_img ?? meData.snoovatar_img), let rootAvatar = rootURL(avatar)?.absoluteString {
            credential.profilePicture = rootAvatar
          }
          return true
        }
        return true
      case .failure(let error):
        print(error)
        return false
      }
    }
    return false
  }
  
  func getAuthCodeFromURL(_ rawUrl: URL) -> String? {
    if let url = URL(string: rawUrl.absoluteString.replacingOccurrences(of: "winstonapp://", with: "https://app.winston.cafe/")), url.lastPathComponent == "auth-success", let query = URLComponents(url: url, resolvingAgainstBaseURL: false), let state = query.queryItems?.first(where: { $0.name == "state" })?.value, let code = query.queryItems?.first(where: { $0.name == "code" })?.value, state == lastAuthState {
//      let res = await injectFirstAccessTokenInto(&credential, authCode: code)
//      lastAuthState = nil
//      return res
      return code
    } else {
      return nil
    }
  }
  
  func  getAuthorizationCodeURL(_ appID: String) -> URL {
    let response_type: String = "code"
    let state: String = UUID().uuidString
    let redirect_uri: String = RedditAPI.appRedirectURI
    let duration: String = "permanent"
    let scope: String = "identity,edit,flair,history,modconfig,modflair,modlog,modposts,modwiki,mysubreddits,privatemessages,read,report,save,submit,subscribe,vote,wikiedit,wikiread"
    
    lastAuthState = state
    
    return URL(string: "https://www.reddit.com/api/v1/authorize.compact?client_id=\(appID.trimmingCharacters(in: .whitespaces))&response_type=\(response_type)&state=\(state)&redirect_uri=\(redirect_uri)&duration=\(duration)&scope=\(scope)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!
  }
  
  struct RefreshAccessTokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let expires_in: Int
    let scope: String
  }
  
  struct GetAccessTokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let refresh_token: String
    let scope: String
    let expires_in: Int
  }
  
  struct RefreshAccessTokenPayload: Encodable {
    let grant_type = "refresh_token"
    let refresh_token: String
  }
  
  struct GetAccessTokenPayload: Encodable {
    let grant_type = "authorization_code"
    let code: String
    let redirect_uri = RedditAPI.appRedirectURI
  }
}

struct ListingChild<T: Codable & Hashable>: Codable, Defaults.Serializable, Hashable {
  let kind: String?
  var data: T?
}

struct Listing<T: Codable & Hashable>: Codable, Defaults.Serializable, Hashable {
  let kind: String?
  var data: ListingData<T>?
}

struct ListingData<T: Codable & Hashable>: Codable, Defaults.Serializable, Hashable {
  let after: String?
  let dist: Int?
  let modhash: String?
  let geo_filter: String?
  var children: [ListingChild<T>]?
}

/// A Reddit listing that skips children that fail to decode, so one odd post can't
/// blank a whole feed page. Only use it where a failed decode isn't relied on
/// (comment threads decode `Either<Listing<PostData>, Listing<CommentData>>`).
struct LossyListing<T: Codable & Hashable>: Decodable {
  let after: String?
  let children: [ListingChild<T>]
  let skippedCount: Int
  let firstSkipError: String?
  
  private enum CodingKeys: String, CodingKey { case data }
  private enum DataKeys: String, CodingKey { case after, children }
  
  private struct LossyChild: Decodable {
    let value: ListingChild<T>?
    let error: String?
    
    init(from decoder: Decoder) throws {
      var decoded: ListingChild<T>? = nil
      var message: String? = nil
      do {
        decoded = try ListingChild<T>(from: decoder)
      } catch {
        message = String(describing: error)
      }
      value = decoded
      self.error = message
    }
  }
  
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let data = try container.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
    after = try data.decodeIfPresent(String.self, forKey: .after)
    let raw = try data.decodeIfPresent([LossyChild].self, forKey: .children) ?? []
    children = raw.compactMap { $0.value }
    skippedCount = raw.count - children.count
    firstSkipError = raw.first(where: { $0.error != nil })?.error
    if let skipError = firstSkipError {
      print("LossyListing skipped \(skippedCount) of \(raw.count) children. First error: \(skipError)")
    }
  }
}

enum Either<A: Codable & Hashable, B: Codable & Hashable>: Codable, Hashable {
  case first(A)
  case second(B)
  
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    
    do {
      let firstType = try container.decode(A.self)
      self = .first(firstType)
    } catch let firstError {
      do {
        let secondType = try container.decode(B.self)
        self = .second(secondType)
      } catch let secondError {
        let context = DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Type mismatch for both types.", underlyingError: Swift.DecodingError.typeMismatch(Any.self, DecodingError.Context.init(codingPath: decoder.codingPath, debugDescription: "First type error: \(firstError). Second type error: \(secondError)")))
        throw DecodingError.dataCorrupted(context)
      }
    }
  }
  
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .first(let value):
      try container.encode(value)
    case .second(let value):
      try container.encode(value)
    }
  }
}

