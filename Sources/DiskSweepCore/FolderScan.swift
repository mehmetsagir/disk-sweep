import Foundation

/// Read-only exploration of any folder. Entries that the safety guard allows to
/// be trashed become selectable; everything else is shown as view-only.
public enum FolderScan {
    public static let categoryID = "folder-scan"

    public static let accessDeniedNote =
        "Bu klasöre erişim reddedildi. Sistem Ayarları → Gizlilik ve Güvenlik → Tam Disk Erişimi'ne DiskSweep'i ekleyip yeniden başlatın."

    /// Direct children, sorted by name. Hidden entries are included.
    public static func listChildren(of directory: URL) -> (urls: [URL], denied: Bool) {
        let (urls, denied) = Scan.children(of: directory)
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (sorted, denied)
    }

    public static func makeItem(url: URL, size: Int64?, guardrail: SafetyGuard) -> CleanupItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
        let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
        let id = "\(categoryID)|\(url.path)"
        let modified = values?.contentModificationDate

        do {
            try guardrail.validateUserTrash(of: url)
            return CleanupItem(
                id: id, categoryID: categoryID, title: url.lastPathComponent,
                detail: isFolder ? "Klasör — Çöp Kutusu'na taşınabilir" : "Dosya — Çöp Kutusu'na taşınabilir",
                size: size, safety: .caution, action: .trashUserSelected(url),
                modified: modified, browseURL: url, isFolder: isFolder)
        } catch {
            return CleanupItem(
                id: id, categoryID: categoryID, title: url.lastPathComponent,
                detail: "\(error)", size: size, safety: .protected, action: .informational,
                modified: modified, browseURL: url, isFolder: isFolder)
        }
    }
}
