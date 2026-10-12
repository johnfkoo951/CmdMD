import Foundation

extension String {
    /// `!=` for document text that settles the usual case in O(1). Text from
    /// the editor is an NSString bridged from NSTextView, for which Swift's
    /// `!=` walks both strings with Unicode normalization (~20 ms at 300k
    /// characters) — and the typing path compared that way at several sites
    /// per keystroke. Its UTF-16 length is O(1), and nearly every edit changes
    /// it; equal lengths still get the full comparison. Unlike `!=`, it also
    /// tells precomposed from decomposed text (é vs e + ◌́): their lengths
    /// differ, and so do the bytes they write.
    func differs(from other: String) -> Bool {
        utf16.count != other.utf16.count || self != other
    }
}
