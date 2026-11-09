import Foundation
import ChessCore

extension OpeningBook {
    /// The book kept with ChessSearch (`Resources/Book/opening-book.txt`), or nil when it is missing or empty. It looks
    /// for the resource bundle in an app's Resources folder and next to a plain executable, never through
    /// `Bundle.module`, which stops the program when the bundle is not where SwiftPM left it.
    public static func bundled() -> OpeningBook? {
        let folders = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for folder in folders {
            let url = folder.appendingPathComponent("ChessAi_ChessSearch.bundle/Book/opening-book.txt")
            if let book = try? OpeningBook(contentsOf: url), book.count > 0 { return book }
        }
        return nil
    }
}
