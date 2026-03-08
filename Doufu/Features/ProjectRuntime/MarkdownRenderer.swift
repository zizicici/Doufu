//
//  MarkdownRenderer.swift
//  Doufu
//
//  Renders Markdown text into NSAttributedString for chat bubbles.
//

import Markdown
import UIKit

/// Converts a Markdown string into a styled `NSAttributedString`.
///
/// Uses Apple's `swift-markdown` library to parse the CommonMark AST,
/// then walks the tree to build a rich attributed string suitable for
/// display inside a `UILabel`.
struct MarkdownRenderer {

    struct Style {
        var bodyFont: UIFont = .systemFont(ofSize: 15)
        var bodyColor: UIColor = .label
        var codeFont: UIFont = .monospacedSystemFont(ofSize: 13.5, weight: .regular)
        var codeColor: UIColor = .label
        var codeBackgroundColor: UIColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.08)
                : UIColor(white: 0, alpha: 0.05)
        }
        var codeBlockBackgroundColor: UIColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.06)
                : UIColor(white: 0, alpha: 0.04)
        }
        var headingColor: UIColor = .label
        var linkColor: UIColor = .systemBlue
        var thematicBreakColor: UIColor = .separator
        var listBulletColor: UIColor = .secondaryLabel
        var paragraphSpacing: CGFloat = 10
    }

    static func render(_ markdown: String, style: Style = Style()) -> NSAttributedString {
        let document = Document(parsing: markdown)
        let visitor = AttributedStringVisitor(style: style)
        return visitor.visit(document)
    }
}

// MARK: - Visitor

private final class AttributedStringVisitor {
    let style: MarkdownRenderer.Style

    private let result = NSMutableAttributedString()
    private var listDepth = 0
    private var orderedListCounters: [Int] = []
    private var isFirstParagraph = true

    init(style: MarkdownRenderer.Style) {
        self.style = style
    }

    // MARK: - Public entry point

    func visit(_ document: Document) -> NSAttributedString {
        visitChildren(of: document)
        // Trim trailing newlines
        let str = result.mutableString
        while str.length > 0 && str.character(at: str.length - 1) == 0x0A {
            str.deleteCharacters(in: NSRange(location: str.length - 1, length: 1))
        }
        return NSAttributedString(attributedString: result)
    }

    // MARK: - Block-level

    private func visitChildren(of markup: any Markup) {
        for child in markup.children {
            visitNode(child)
        }
    }

    private func visitNode(_ node: any Markup) {
        switch node {
        case let paragraph as Paragraph:
            visitParagraph(paragraph)
        case let heading as Heading:
            visitHeading(heading)
        case let codeBlock as CodeBlock:
            visitCodeBlock(codeBlock)
        case let list as UnorderedList:
            visitUnorderedList(list)
        case let list as OrderedList:
            visitOrderedList(list)
        case let item as ListItem:
            visitListItem(item)
        case let blockQuote as BlockQuote:
            visitBlockQuote(blockQuote)
        case let thematicBreak as ThematicBreak:
            visitThematicBreak(thematicBreak)
        // Inline
        case let text as Markdown.Text:
            appendText(text.string)
        case let strong as Strong:
            visitStrong(strong)
        case let emphasis as Emphasis:
            visitEmphasis(emphasis)
        case let strikethrough as Strikethrough:
            visitStrikethrough(strikethrough)
        case let inlineCode as InlineCode:
            visitInlineCode(inlineCode)
        case let link as Markdown.Link:
            visitLink(link)
        case let image as Markdown.Image:
            visitImage(image)
        case is SoftBreak:
            appendText(" ")
        case is LineBreak:
            appendText("\n")
        case let html as HTMLBlock:
            appendText(html.rawHTML)
        case let inlineHTML as InlineHTML:
            appendText(inlineHTML.rawHTML)
        default:
            // Fallback: visit children
            visitChildren(of: node)
        }
    }

    // MARK: - Block visitors

    private func visitParagraph(_ paragraph: Paragraph) {
        if !isFirstParagraph {
            ensureNewline()
            appendNewline()
        }
        isFirstParagraph = false
        visitChildren(of: paragraph)
    }

    private func visitHeading(_ heading: Heading) {
        if !isFirstParagraph {
            ensureNewline()
            appendNewline()
        }
        isFirstParagraph = false

        let savedResult = snapshotLength()
        visitChildren(of: heading)
        let range = NSRange(location: savedResult, length: result.length - savedResult)

        let fontSize: CGFloat
        switch heading.level {
        case 1: fontSize = style.bodyFont.pointSize * 1.5
        case 2: fontSize = style.bodyFont.pointSize * 1.3
        case 3: fontSize = style.bodyFont.pointSize * 1.15
        default: fontSize = style.bodyFont.pointSize * 1.05
        }
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        result.addAttribute(.font, value: font, range: range)
        result.addAttribute(.foregroundColor, value: style.headingColor, range: range)
    }

    private func visitCodeBlock(_ codeBlock: CodeBlock) {
        if !isFirstParagraph {
            ensureNewline()
            appendNewline()
        }
        isFirstParagraph = false

        var code = codeBlock.code
        // Remove trailing newline that cmark adds
        if code.hasSuffix("\n") {
            code = String(code.dropLast())
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: style.codeFont,
            .foregroundColor: style.codeColor,
            .backgroundColor: style.codeBlockBackgroundColor,
        ]
        result.append(NSAttributedString(string: code, attributes: attrs))
    }

    private func visitUnorderedList(_ list: UnorderedList) {
        listDepth += 1
        for child in list.children {
            visitNode(child)
        }
        listDepth -= 1
    }

    private func visitOrderedList(_ list: OrderedList) {
        listDepth += 1
        orderedListCounters.append(0)
        for child in list.children {
            visitNode(child)
        }
        orderedListCounters.removeLast()
        listDepth -= 1
    }

    private func visitListItem(_ item: ListItem) {
        if !isFirstParagraph {
            ensureNewline()
        }
        isFirstParagraph = false

        let indent = String(repeating: "  ", count: max(0, listDepth - 1))
        let bullet: String
        if !orderedListCounters.isEmpty {
            orderedListCounters[orderedListCounters.count - 1] += 1
            bullet = "\(orderedListCounters.last!)."
        } else {
            bullet = "\u{2022}"
        }
        let prefix = "\(indent)\(bullet) "
        let attrs: [NSAttributedString.Key: Any] = [
            .font: style.bodyFont,
            .foregroundColor: style.listBulletColor,
        ]
        result.append(NSAttributedString(string: prefix, attributes: attrs))

        // Render children inline (don't add paragraph spacing inside list items)
        let savedFirst = isFirstParagraph
        isFirstParagraph = true
        for child in item.children {
            visitNode(child)
        }
        isFirstParagraph = savedFirst
    }

    private func visitBlockQuote(_ blockQuote: BlockQuote) {
        if !isFirstParagraph {
            ensureNewline()
            appendNewline()
        }
        isFirstParagraph = false

        let savedLen = snapshotLength()
        let savedFirst = isFirstParagraph
        isFirstParagraph = true
        visitChildren(of: blockQuote)
        isFirstParagraph = savedFirst

        // Prefix each line with "┃ " after the fact
        let range = NSRange(location: savedLen, length: result.length - savedLen)
        let text = result.mutableString.substring(with: range)
        let prefixed = text.components(separatedBy: "\n")
            .map { "┃ " + $0 }
            .joined(separator: "\n")
        result.replaceCharacters(in: range, with: prefixed)

        let updatedRange = NSRange(location: savedLen, length: result.length - savedLen)
        result.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: updatedRange)
    }

    private func visitThematicBreak(_ _: ThematicBreak) {
        ensureNewline()
        let separator = String(repeating: "\u{2500}", count: 30)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: style.bodyFont,
            .foregroundColor: style.thematicBreakColor,
        ]
        result.append(NSAttributedString(string: separator, attributes: attrs))
    }

    // MARK: - Inline visitors

    private func appendText(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: style.bodyFont,
            .foregroundColor: style.bodyColor,
        ]
        result.append(NSAttributedString(string: text, attributes: attrs))
    }

    private func visitStrong(_ strong: Strong) {
        let savedLen = snapshotLength()
        visitChildren(of: strong)
        let range = NSRange(location: savedLen, length: result.length - savedLen)
        let bold = UIFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold)
        result.addAttribute(.font, value: bold, range: range)
    }

    private func visitEmphasis(_ emphasis: Emphasis) {
        let savedLen = snapshotLength()
        visitChildren(of: emphasis)
        let range = NSRange(location: savedLen, length: result.length - savedLen)
        let italic = UIFont.italicSystemFont(ofSize: style.bodyFont.pointSize)
        result.addAttribute(.font, value: italic, range: range)
    }

    private func visitStrikethrough(_ strikethrough: Strikethrough) {
        let savedLen = snapshotLength()
        visitChildren(of: strikethrough)
        let range = NSRange(location: savedLen, length: result.length - savedLen)
        result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    }

    private func visitInlineCode(_ inlineCode: InlineCode) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: style.codeFont,
            .foregroundColor: style.codeColor,
            .backgroundColor: style.codeBackgroundColor,
        ]
        result.append(NSAttributedString(string: inlineCode.code, attributes: attrs))
    }

    private func visitLink(_ link: Markdown.Link) {
        let savedLen = snapshotLength()
        visitChildren(of: link)
        let range = NSRange(location: savedLen, length: result.length - savedLen)
        result.addAttribute(.foregroundColor, value: style.linkColor, range: range)
        if let destination = link.destination, let url = URL(string: destination) {
            result.addAttribute(.link, value: url, range: range)
        }
        result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    }

    private func visitImage(_ image: Markdown.Image) {
        // Show alt text as fallback
        let alt = image.plainText
        if !alt.isEmpty {
            appendText("[\(alt)]")
        }
    }

    // MARK: - Helpers

    private func snapshotLength() -> Int {
        result.length
    }

    private func ensureNewline() {
        if result.length > 0 && result.mutableString.character(at: result.length - 1) != 0x0A {
            result.mutableString.append("\n")
        }
    }

    private func appendNewline() {
        result.mutableString.append("\n")
    }
}
