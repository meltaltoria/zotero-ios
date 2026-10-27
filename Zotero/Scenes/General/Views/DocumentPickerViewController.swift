//
//  DocumentPickerViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 20/02/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import RxSwift

/// File providers can grant read-only, security-scoped URLs. Import a coordinated copy; never move the user's original.
enum LocalFileImporter {
    static func copy(from source: URL, to destination: File, fileStorage: FileStorage) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
            do {
                let values = try readableURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                try fileStorage.copy(from: readableURL.path, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}

final class DocumentPickerViewController: UIDocumentPickerViewController {
    let observable: PublishSubject<[URL]> = PublishSubject()

    override func viewDidLoad() {
        super.viewDidLoad()

        self.delegate = self
    }
}

extension DocumentPickerViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.observable.on(.next(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.dismiss(animated: true, completion: nil)
    }
}
