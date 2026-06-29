import Foundation

/// Exports transcriptions to multiple file formats.
struct ExportService {
    
    enum ExportFormat: String, CaseIterable, Identifiable {
        case txt = "Plain Text"
        case srt = "SRT Subtitles"
        case vtt = "WebVTT"
        case json = "JSON"
        case csv = "CSV"
        case md = "Markdown"
        
        var id: String { rawValue }
        
        var fileExtension: String {
            switch self {
            case .txt: return "txt"
            case .srt: return "srt"
            case .vtt: return "vtt"
            case .json: return "json"
            case .csv: return "csv"
            case .md: return "md"
            }
        }
        
        var icon: String {
            switch self {
            case .txt: return "doc.text"
            case .srt: return "captions.bubble"
            case .vtt: return "film"
            case .json: return "curlybraces"
            case .csv: return "tablecells"
            case .md: return "doc.richtext"
            }
        }
        
        var description: String {
            switch self {
            case .txt: return "Simple text with timestamps"
            case .srt: return "Standard subtitle format"
            case .vtt: return "Web video subtitles"
            case .json: return "Structured data with metadata"
            case .csv: return "Spreadsheet-compatible"
            case .md: return "Rich formatted document"
            }
        }
    }
    
    static func export(_ transcription: Transcription, format: ExportFormat) throws -> Data {
        switch format {
        case .txt: return exportTXT(transcription)
        case .srt: return exportSRT(transcription)
        case .vtt: return exportVTT(transcription)
        case .json: return exportJSON(transcription)
        case .csv: return exportCSV(transcription)
        case .md: return exportMarkdown(transcription)
        }
    }
    
    static func exportToFile(_ transcription: Transcription, format: ExportFormat) throws -> URL {
        let data = try export(transcription, format: format)
        let fileName = "\(transcription.title.sanitizedForFilename).\(format.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: url)
        return url
    }
    
    // MARK: - TXT
    
    private static func exportTXT(_ t: Transcription) -> Data {
        var lines: [String] = []
        lines.append(t.title)
        lines.append(String(repeating: "=", count: t.title.count))
        lines.append("")
        lines.append("Duration: \(formatDuration(t.duration))")
        lines.append("Language: \(t.detectedLanguage)")
        lines.append("Model: \(t.modelName)")
        lines.append("Date: \(t.createdAt.formatted(date: .abbreviated, time: .shortened))")
        lines.append("")
        lines.append("---")
        lines.append("")
        
        let segments = t.segments
        if segments.isEmpty {
            lines.append(t.fullText)
        } else {
            for seg in segments {
                lines.append("[\(seg.startTimeFormatted) → \(seg.endTimeFormatted)]")
                lines.append(seg.text)
                lines.append("")
            }
        }
        
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }
    
    // MARK: - SRT
    
    private static func exportSRT(_ t: Transcription) -> Data {
        var srt = ""
        for (i, seg) in t.segments.enumerated() {
            srt += "\(i + 1)\n"
            srt += "\(formatSRT(seg.start)) --> \(formatSRT(seg.end))\n"
            srt += "\(seg.text)\n\n"
        }
        return srt.data(using: .utf8) ?? Data()
    }
    
    // MARK: - VTT
    
    private static func exportVTT(_ t: Transcription) -> Data {
        var vtt = "WEBVTT\n\n"
        for (i, seg) in t.segments.enumerated() {
            vtt += "\(i + 1)\n"
            vtt += "\(formatVTT(seg.start)) --> \(formatVTT(seg.end))\n"
            vtt += "\(seg.text)\n\n"
        }
        return vtt.data(using: .utf8) ?? Data()
    }
    
    // MARK: - JSON
    
    private static func exportJSON(_ t: Transcription) -> Data {
        let output: [String: Any] = [
            "title": t.title,
            "created_at": ISO8601DateFormatter().string(from: t.createdAt),
            "duration_seconds": t.duration,
            "language": t.detectedLanguage,
            "model": t.modelName,
            "word_count": t.wordCount,
            "full_text": t.fullText,
            "segments": t.segments.map { seg -> [String: Any] in
                [
                    "id": seg.id,
                    "start": seg.start,
                    "end": seg.end,
                    "duration": seg.end - seg.start,
                    "text": seg.text
                ]
            }
        ]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
    
    // MARK: - CSV
    
    private static func exportCSV(_ t: Transcription) -> Data {
        var csv = "id,start_seconds,end_seconds,duration_seconds,text\n"
        for seg in t.segments {
            let escaped = seg.text.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\(seg.id),\(String(format: "%.3f", seg.start)),\(String(format: "%.3f", seg.end)),\(String(format: "%.3f", seg.end - seg.start)),\"\(escaped)\"\n"
        }
        return csv.data(using: .utf8) ?? Data()
    }
    
    // MARK: - Markdown
    
    private static func exportMarkdown(_ t: Transcription) -> Data {
        var md = "# \(t.title)\n\n"
        md += "| | |\n|---|---|\n"
        md += "| **Duration** | \(formatDuration(t.duration)) |\n"
        md += "| **Language** | \(t.detectedLanguage) |\n"
        md += "| **Model** | \(t.modelName) |\n"
        md += "| **Words** | \(t.wordCount) |\n"
        md += "| **Date** | \(t.createdAt.formatted(date: .abbreviated, time: .shortened)) |\n\n"
        md += "## Full Text\n\n\(t.fullText)\n\n"
        
        if !t.segments.isEmpty {
            md += "## Timestamped Segments\n\n"
            md += "| Time | Text |\n|------|------|\n"
            for seg in t.segments {
                let escaped = seg.text.replacingOccurrences(of: "|", with: "\\|")
                md += "| `\(seg.startTimeFormatted)` | \(escaped) |\n"
            }
        }
        
        return md.data(using: .utf8) ?? Data()
    }
    
    // MARK: - Formatters
    
    private static func formatSRT(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
    
    private static func formatVTT(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
    
    static func formatDuration(_ duration: Double) -> String {
        let h = Int(duration) / 3600
        let m = (Int(duration) % 3600) / 60
        let s = Int(duration) % 60
        if h > 0 {
            return String(format: "%dh %02dm %02ds", h, m, s)
        }
        return String(format: "%dm %02ds", m, s)
    }
}

// MARK: - String Extension

private extension String {
    var sanitizedForFilename: String {
        let invalid = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return components(separatedBy: invalid).joined(separator: "_")
            .prefix(100).description
    }
}
