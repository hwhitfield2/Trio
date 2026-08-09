import SwiftUI
import UIKit

enum ClinicReportPDFError: LocalizedError {
    case documentsDirectoryNotFound
    case pageRenderingFailed

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryNotFound:
            return String(localized: "The Documents folder could not be found.")
        case .pageRenderingFailed:
            return String(localized: "A report page could not be rendered.")
        }
    }
}

/// Renders the AGP report pages (SwiftUI views) into a paginated PDF in the
/// app's Documents directory and returns the file URL for sharing.
enum ClinicReportPDFRenderer {
    /// A4 at 72 dpi.
    static let pageSize = CGSize(width: 595, height: 842)
    /// Daily thumbnails per follow-up page (7 rows x 2 columns).
    static let daysPerPage = 14

    @MainActor static func render(data: AGPReportData, units: GlucoseUnits) throws -> URL {
        var pages: [AnyView] = [ClinicReportSummaryPage(data: data, units: units).asAny()]

        let days = data.dailySeries
        var index = 0
        while index < days.count {
            let chunk = Array(days[index ..< min(index + daysPerPage, days.count)])
            pages.append(ClinicReportDailyPage(days: chunk, units: units).asAny())
            index += daysPerPage
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "TrioAGPReport_\(formatter.string(from: Date())).pdf"

        let fileManager = FileManager.default
        // Use the Documents directory for better sharing compatibility.
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ClinicReportPDFError.documentsDirectoryNotFound
        }
        let fileURL = documentsDirectory.appendingPathComponent(fileName)

        let bounds = CGRect(origin: .zero, size: pageSize)
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: bounds)
        var renderingFailed = false
        try pdfRenderer.writePDF(to: fileURL) { context in
            for page in pages {
                let imageRenderer = ImageRenderer(
                    content: page
                        .frame(width: pageSize.width, height: pageSize.height)
                        .environment(\.colorScheme, .light)
                )
                imageRenderer.scale = 2
                guard let image = imageRenderer.uiImage else {
                    renderingFailed = true
                    continue
                }
                context.beginPage()
                image.draw(in: bounds)
            }
        }

        if renderingFailed {
            try? fileManager.removeItem(at: fileURL)
            throw ClinicReportPDFError.pageRenderingFailed
        }

        try fileManager.setAttributes([.posixPermissions: 0o644, .extensionHidden: false], ofItemAtPath: fileURL.path)
        return fileURL
    }
}
