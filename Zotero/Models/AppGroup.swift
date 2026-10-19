//
//  AppGroup.swift
//  Zotero
//
//  Created by Michal Rentka on 26/11/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct AppGroup {
    // Personal-team sideload builds keep all data inside the application's own sandbox.
    static var sharedContainerIdentifier: String? {
#if SIDELOAD
        return nil
#else
        return identifier
#endif
    }

    static var cookieStorage: HTTPCookieStorage {
        guard let identifier = sharedContainerIdentifier else { return .shared }
        return HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: identifier)
    }

    static var identifier: String {
        return "group.org.zotero.ios.Zotero"
    }
}
