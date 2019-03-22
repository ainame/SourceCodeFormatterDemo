import Foundation
import Path
import SwiftSyntax
import Basic

extension SyntaxRewriter {

    fileprivate func getOffset(from trivia: Trivia?) -> Int {

        guard let trivia = trivia else { return 0 }
        return trivia.compactMap {
            if case .spaces(let x) = $0 {
                return x
            } else {
                return nil
            }
        }.first ?? 0
    }
}

class FirstTokenRewriter: SyntaxRewriter {

    private let rewrite: (TokenSyntax) -> TokenSyntax

    private var hasRewritten = false

    init(rewrite: @escaping (TokenSyntax) -> TokenSyntax) {
        self.rewrite = rewrite
    }

    override func visit(_ token: TokenSyntax) -> Syntax {
        guard !self.hasRewritten else {
            return super.visit(token)
        }

        self.hasRewritten = true

        let token2 = self.rewrite(token)

        return super.visit(token2)
    }
}

protocol CodeBlockParentable: DeclSyntax {

    var body: CodeBlockSyntax? { get }

    func withBody(_ codeBlock: CodeBlockSyntax?) -> Self
}

extension FunctionDeclSyntax: CodeBlockParentable {}

extension InitializerDeclSyntax: CodeBlockParentable {}

class InsertEmptyLineToTheHeadOfMethod: SyntaxRewriter {

    let numberOfEmptyLines: Int

    init(numberOfEmptyLines: Int = 1) {
        self.numberOfEmptyLines = numberOfEmptyLines
    }

    override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {

        return formatCodeBlockWithoutRedundantEmptyLines(node)
    }

    override func visit(_ node: InitializerDeclSyntax) -> DeclSyntax {

        return formatCodeBlockWithoutRedundantEmptyLines(node)
    }

    private func formatCodeBlockWithoutRedundantEmptyLines<T: CodeBlockParentable>(_ node: T) -> DeclSyntax {

        guard let body1 = node.body,
            case .spaces? = node.leadingTrivia?[1] else {
                return node
        }

        var newStatements = body1.statements
        if !newStatements.isEmpty {
            var newStatement = newStatements[0]
            newStatement = SyntaxFactory.makeCodeBlockItem(item: formatStatementWithoutRedundantEmptyLines(newStatement.item),
                                                           semicolon: nil)
            newStatements = newStatements.replacing(childAt: 0, with: newStatement)
        }
        let body2 = body1.withStatements(newStatements)
        return node.withBody(body2)
    }

    private func formatStatementWithoutRedundantEmptyLines(_ syntax: Syntax) -> Syntax {

        let offset: Int = getOffset(from: syntax.leadingTrivia)
        let leadingTrivia: Trivia = Trivia(pieces: [.newlines(1 + numberOfEmptyLines), .spaces(offset)])
        return FirstTokenRewriter { $0.withLeadingTrivia(leadingTrivia) }.visit(syntax)
    }
}

class CompositionTypeSorter: SyntaxRewriter {

    override func visit(_ node: CompositionTypeSyntax) -> TypeSyntax {

        guard !node.elements.isEmpty else { return super.visit(node) }

        let sortedElements = node.elements.sorted(by: { a, b in
            return a.type.description.compare(b.type.description) == .orderedAscending
        })

        let offset = getOffset(from: node.parent?.parent?.leadingTrivia) // Take the offset from "typealias Context"
        let ampersand = SyntaxFactory.makePrefixAmpersandToken()

        var modifiedElements = [CompositionTypeElementSyntax]()
        sortedElements.enumerated().forEach { index, element in
            let trimmedTypeName = element.type.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let typeToken = SyntaxFactory.makeToken(TokenKind.identifier(trimmedTypeName),
                                                    presence: element.type.isPresent ? .present : .missing,
                                                    leadingTrivia: Trivia(pieces: [.newlines(1), .spaces(offset + 4)]),
                                                    trailingTrivia: .zero)
            let typeIdentifier = SyntaxFactory.makeSimpleTypeIdentifier(name: typeToken, genericArgumentClause: nil)
            let ampersand = index == (sortedElements.count - 1) ? nil : ampersand.withLeadingTrivia(Trivia(pieces: [.spaces(1)]))
            let compositionType = SyntaxFactory.makeCompositionTypeElement(type: typeIdentifier, ampersand: ampersand)
            modifiedElements.append(compositionType)
        }

        let newChild = SyntaxFactory.makeCompositionTypeElementList(modifiedElements)
        return node.withElements(newChild)
    }
}

class SortCompositionTypeInAlphabeticalOrder: SyntaxRewriter {

    let typeName: String?

    init(typeName: String?) {
        self.typeName = typeName
    }

    override func visit(_ node: TypealiasDeclSyntax) -> DeclSyntax {

        if let typeName = typeName, node.identifier.text != typeName {
            return super.visit(node)
        }

        guard let initializer = node.initializer,
            let value = initializer.value as? CompositionTypeSyntax else {
            return super.visit(node)
        }

        let newValue = CompositionTypeSorter().visit(value)
        let newInitializer = SyntaxFactory.makeTypeInitializerClause(equal: initializer.equal, value: newValue)
        return SyntaxFactory.makeTypealiasDecl(attributes: node.attributes,
                                               modifiers: node.modifiers,
                                               typealiasKeyword: node.typealiasKeyword,
                                               identifier: node.identifier,
                                               genericParameterClause: node.genericParameterClause,
                                               initializer: newInitializer,
                                               genericWhereClause: node.genericWhereClause)
    }
}

func visit(file: Path) throws {

    guard file.string.hasSuffix(".swift") else { return }

    let tempfile = try TemporaryFile(deleteOnClose: true)
    defer { tempfile.fileHandle.closeFile() }
    try tempfile.fileHandle.write(String(contentsOf: file).data(using: .utf8)!)

    let url = URL(fileURLWithPath: tempfile.path.asString)
    let sourceFile = try SyntaxTreeParser.parse(url)
    var modifiedSource = InsertEmptyLineToTheHeadOfMethod().visit(sourceFile)
    modifiedSource = SortCompositionTypeInAlphabeticalOrder(typeName: "Context").visit(modifiedSource)
    print(modifiedSource.description.prefix(500))
}

try visit(file: Path("/Path/To/file"))
