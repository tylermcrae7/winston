//
//  newCredentialListener.swift
//  winston
//
//  Created by Igor Marcossi on 10/12/23.
//

import Foundation
import SwiftUI

struct NewCredentialListenerModifier: ViewModifier {
  @ObservedObject private var nav = Nav.shared
  @ObservedObject private var redditCredentialsManager = RedditCredentialsManager.shared
  func body(content: Content) -> some View {
    content
      .onOpenURL { url in
        if case .editingCredential(_) = nav.presentingSheet {} else if let queryParams = url.queryParameters, let appID = queryParams["appID"], let appSecret = queryParams["appSecret"] {
          let normalizedAppID = RedditAPI.normalizedCredentialComponent(appID)
          let normalizedAppSecret = RedditAPI.normalizedCredentialComponent(appSecret)
          if var foundCred = redditCredentialsManager.credentials.first(where: { RedditAPI.normalizedCredentialComponent($0.apiAppID) == normalizedAppID }) {
            foundCred.apiAppSecret = normalizedAppSecret
            Nav.present(.editingCredential(foundCred))
          } else {
            Nav.present(.editingCredential(.init(apiAppID: normalizedAppID, apiAppSecret: normalizedAppSecret)))
          }
        }
      }
  }
}

extension View {
  func newCredentialListener() -> some View {
    self.modifier(NewCredentialListenerModifier())
  }
}
