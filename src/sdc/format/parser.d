module sdc.format.parser;

/**
 * While we already have a parser in libd, we cannot use it here.
 * This is because libd's parser is meant to validate that the source
 * is well a formed D program. However, we want to be able to format
 * even incomplete programs as part of the developper's process.
 *
 * This parser, on the other hand, is meant to recognize common patterns
 * in the language, without ensuring that they are indeed correct.
 */
struct Parser {
private:
	import d.context;
	Context context;
	
	import d.lexer;
	TokenRange trange;
	
	import sdc.format.chunk;
	Builder builder;
	
	enum Mode {
		Declaration,
		Statement,
		Parameter,
	}

	Mode mode;
	
	auto changeMode(Mode m) {
		static struct Guard {
			~this() {
				parser.mode = oldMode;
			}
			
		private:
			Parser* parser;
			Mode oldMode;
		}
		
		Mode oldMode = mode;
		mode = m;
		
		return Guard(&this, oldMode);
	}
	
	/**
	 * When we can't parse we skip and forward chunks "as this"
	 */
	Location skipped;
	
public:	
	this(Context context, ref TokenRange trange) {
		this.context = context;
		this.trange = trange.withComments();
	}
	
	Chunk[] parse() in {
		assert(match(TokenType.Begin));
	} body {
		// Eat the begin token and get the game rolling.
		nextToken();
		parseModule();
		
		assert(match(TokenType.End));
		
		emitSkippedTokens();
		return builder.build();
	}

private:
	/**
	 * Token Processing.
	 */
	import d.context.location;
	uint getStartLineNumber(Location loc) {
		return loc.getFullLocation(context).getStartLineNumber();
	}
	
	uint getLineNumber(Position p) {
		return p.getFullPosition(context).getLineNumber();
	}
	
	int newLineCount(ref TokenRange r) {
		return getStartLineNumber(r.front.location) - getLineNumber(r.previous);
	}
	
	int newLineCount() {
		return newLineCount(trange);
	}
	
	uint getStartOffset(Location loc) {
		return loc.getFullLocation(context).getStartOffset();
	}
	
	uint getSourceOffset(Position p) {
		return p.getFullPosition(context).getSourceOffset();
	}
	
	int whiteSpaceLength(ref TokenRange r) {
		return getStartOffset(r.front.location) - getSourceOffset(r.previous);
	}
	
	int whiteSpaceLength() {
		return whiteSpaceLength(trange);
	}
	
	@property
	Token token() const {
		return trange.front;
	}
	
	void nextToken() {
		emitSkippedTokens();
		
		// Process current token.
		builder.write(token.toString(context));
		
		if (match(TokenType.End)) {
			// We reached the end of our input.
			return;
		}
		
		trange.popFront();
		emitComments();
	}
	
	/**
	 * We skip over portions of the code we can't parse.
	 */
	void skipToken() {
		if (skipped.length == 0) {
			emitSourceBasedWhiteSpace();
			split();
			
			skipped = token.location;
		} else {
			skipped.spanTo(token.location);
		}
		
		trange.popFront();
		
		// Skip over comment that look related too.
		while (match(TokenType.Comment) && newLineCount() == 0) {
			skipped.spanTo(token.location);
			trange.popFront();
		}
		
		emitComments();
	}
	
	void emitSkippedTokens() {
		if (skipped.length == 0) {
			return;
		}
		
		builder.write(skipped.getFullLocation(context).getSlice());
		skipped = Location.init;
		
		emitSourceBasedWhiteSpace();
		split();
	}
	
	/**
	 * Comments management
	 */
	void emitComments() {
		if (!match(TokenType.Comment)) {
			return;
		}
		
		emitSkippedTokens();
		emitSourceBasedWhiteSpace();
		
		// TODO: Process comments here.
		while (match(TokenType.Comment)) {
			auto comment = token.toString(context);
			builder.write(comment);
			
			trange.popFront();
			
			if (comment[0 .. 2] == "//") {
				newline(newLineCount() + 1);
			} else {
				emitSourceBasedWhiteSpace();
			}
		}
	}
	
	/**
	 * Chunk builder facilities
	 */
	void space() {
		builder.space();
	}
	
	void newline() {
		newline(newLineCount());
	}
	
	void newline(int nl) {
		builder.newline(nl);
	}
	
	void clearSplitType() {
		builder.clearSplitType();
	}
	
	void split() {
		builder.split();
	}
	
	void emitSourceBasedWhiteSpace() {
		auto nl = newLineCount();
		if (nl) {
			newline(nl);
		} else if (whiteSpaceLength() > 0) {
			space();
		}
	}
	
	/**
	 * Parser utilities
	 */
	bool match(TokenType t) {
		return token.type == t;
	}
	
	auto runOnType(TokenType T, alias fun)() {
		if (match(T)) {
			return fun();
		}
	}
	
	/**
	 * Parsing
	 */
	void parseModule() {
		auto guard = changeMode(Mode.Declaration);
		
		while (!match(TokenType.End)) {
			parseStructuralElement();
		}
	}
	
	void parseStructuralElement() {
		Entry:
		switch (token.type) with(TokenType) {
			case End:
				return;
			
			case Module:
				parseModuleDeclaration();
				break;
			
			/**
			 * Statements
			 */
			case OpenBrace:
				parseBlock(mode);
				
				// Blocks do not end with a semicolon.
				return;
			
			case Identifier:
				auto lookahead = trange.save.withComments(false);
				lookahead.popFront();
				
				if (lookahead.front.type != Colon) {
					// This is an expression or a declaration.
					goto default;
				}
				
				lookahead.popFront();
				if (newLineCount(lookahead)) {
					auto guard = builder.unindent();
					newline(2);
					nextToken();
					nextToken();
					newline();
				} else {
					nextToken();
					nextToken();
					space();
				}

				break;
			
			case If:
				parseIf();
				break;
			
			case Else:
				parseElse();
				break;
			
			case While:
				parseWhile();
				break;
			
			case Do:
				parseDoWhile();
				break;
			
			case For:
				parseFor();
				break;
			
			case Foreach, ForeachReverse:
				parseForeach();
				break;
			
			case Return:
				parseReturn();
				break;
			
			case Break, Continue:
				nextToken();
				runOnType!(Identifier, nextToken)();
				break;
			
			case Switch:
				parseSwitch();
				break;
			
			case Case: {
					auto guard = builder.unindent();
					newline();
					nextToken();
					space();
					
					parseList!parseExpression(TokenType.Colon);
					newline();
				}
				
				break;
			
			case Default: {
					auto guard = builder.unindent();
					newline();
					nextToken();
					runOnType!(Colon, nextToken)();
					newline();
				}
				
				break;

			case Goto:
				nextToken();
				if (match(Identifier) || match(Case) || match(Default)) {
					space();
					nextToken();
				}
				
				break;
			
			case Scope:
				// FIXME: scope statements.
				goto StorageClass;
			
			case Assert:
				parseExpression();
				break;
			
			case Throw, Try:
				goto default;
			
			/**
			 * Declaration
			 */
			case This:
				// FIXME: customized parsing depending if declaration or statement are prefered.
				// For now, assume ctor.
				parseConstructor();
				break;
			
			case Synchronized:
				goto StorageClass;
			
			case Mixin:
				goto default;
			
			case Static:
				nextToken();
				space();
				goto Entry;
			
			case Version, Debug:
				goto default;
			
			case Enum:
				auto lookahead = trange.save.withComments(false);
				lookahead.popFront();
				
				if (lookahead.front.type == Identifier) {
					lookahead.popFront();
				}
				
				if (lookahead.front.type == Colon || lookahead.front.type == OpenBrace) {
					parseEnum();
					break;
				}
				
				goto StorageClass;
			
			case Ref:
				nextToken();
				space();
				goto default;
			
			case Abstract, Align, Auto, Deprecated, Extern, Final, Nothrow, Override, Pure:
			StorageClass:
				parseStorageClass();
				break;
			
			case Struct, Union, Class, Interface:
				parseAggregate();
				break;
			
			case Alias:
				parseAlias();
				break;
			
			default:
				if (!parseIdentifier()) {
					// We made no progress, start skipping.
					skipToken();
					return;
				}
				
				switch (token.type) {
					case Star:
						auto lookahead = trange.save.withComments(false);
						lookahead.popFront();
						
						if (lookahead.front.type != Identifier) {
							break;
						}
						
						// This is a pointer type.
						nextToken();
						goto case;
					
					case Identifier:
						// We have a declaration.
						parseTypedDeclaration();
						break;
					
					default:
						break;
				}
				
				// We just have some kind of expression.
				parseBinaryExpression();
				break;
		}
		
		bool foundSemicolon = match(TokenType.Semicolon);
		if (foundSemicolon) {
			nextToken();
		}
		
		if (mode != Mode.Parameter) {
			if (foundSemicolon) {
				newline();
			} else {
				emitSourceBasedWhiteSpace();
			}
		}
	}
	
	/**
	 * Structural elements.
	 */
	void parseModuleDeclaration() in {
		assert (match(TokenType.Module));
	} body {
		nextToken();
		space();
		parseIdentifier();
	}
	
	/**
	 * Identifiers
	 */
	bool parseIdentifier() {
		bool prefix = parseIdentifierPrefix();
		bool base = parseBaseIdentifier();
		return prefix || base;
	}
	
	bool parseIdentifierPrefix() {
		bool ret = false;
		while (true) {
			scope(success) {
				// This will be true after the first loop iterration.
				ret = true;
			}

			switch (token.type) with(TokenType) {
				// Prefixes.
				case Dot:
				case Ampersand:
				case PlusPlus:
				case MinusMinus:
				case Star:
				case Plus:
				case Minus:
				case Bang:
				case Tilde:
					nextToken();
					break;
				
				case Cast:
					nextToken();
					if (match(OpenParen)) {
						nextToken();
						parseType();
					}
					
					runOnType!(CloseParen, nextToken)();
					space();
					break;
				
				default:
					return ret;
			}
		}
	}
	
	bool parseBaseIdentifier() {
		BaseIdentifier:
		switch (token.type) with(TokenType) {
			case Identifier:
				nextToken();
				break;
			
			// Litterals
			case This:
			case Super:
			case True:
			case False:
			case Null:
			case IntegerLiteral:
			case StringLiteral:
			case CharacterLiteral:
			case __File__:
			case __Line__:
			case Dollar:
				nextToken();
				break;
			
			case Assert:
				nextToken();
				parseArgumentList();
				break;
				
			
			case OpenParen:
				// TODO: lambdas
				parseArgumentList();
				break;
			
			case OpenBracket:
				// TODO: maps
				parseArgumentList();
				break;
			
			// Types
			case Typeof:
				nextToken();
				parseArgumentList();
				break;
			
			case Bool:
			case Byte, Ubyte:
			case Short, Ushort:
			case Int, Uint:
			case Long, Ulong:
			case Cent, Ucent:
			case Char, Wchar, Dchar:
			case Float, Double, Real:
			case Void:
				nextToken();
				break;
			
			// Type qualifiers
			case Const, Immutable, Inout, Shared:
				nextToken();
				if (!match(OpenParen)) {
					space();
					goto BaseIdentifier;
				}
				
				nextToken();
				parseType();
				runOnType!(CloseParen, nextToken)();
				break;
			
			default:
				return false;
		}
		
		parseIdentifierSuffix();
		return true;
	}
	
	bool parseIdentifierSuffix() {
		bool ret = false;
		while (true) {
			scope(success) {
				// This will be true after the first loop iterration.
				ret = true;
			}

			switch (token.type) with(TokenType) {
				case Dot:
					nextToken();
					// Put another coin in the Pachinko!
					parseBaseIdentifier();
					return true;
				
				case Bang:
					nextToken();
					if (match(OpenParen)) {
						parseArgumentList();
					}
					
					break;
				
				case PlusPlus, MinusMinus:
					nextToken();
					break;
				
				case OpenParen, OpenBracket:
					parseArgumentList();
					break;
				
				default:
					return ret;
			}
		}
	}
	
	/**
	 * Statements
	 */
	void parseBlock(Mode m, uint indentLevel = 1) {
		if (!match(TokenType.OpenBrace)) {
			return;
		}
		
		nextToken();
		if (match(TokenType.CloseBrace)) {
			nextToken();
			newline();
			return;
		}
		
		{
			auto indentGuard = builder.indent(indentLevel);
			auto modeGuard = changeMode(m);
			
			newline(1);
			split();
			
			while (!match(TokenType.CloseBrace) && !match(TokenType.End)) {
				parseStructuralElement();
			}
		}
		
		if (match(TokenType.CloseBrace)) {
			clearSplitType();
			newline(1);
			nextToken();
			newline(2);
		}
	}
	
	bool parseControlFlowBlock(uint indentLevel = 1) {
		bool isBlock = match(TokenType.OpenBrace);
		if (isBlock) {
			parseBlock(mode, indentLevel);
		} else {
			auto guard = builder.indent();
			newline(1);
			parseStructuralElement();
		}
		
		return isBlock;
	}
	
	bool parseControlFlowBase(uint indentLevel = 1) {
		nextToken();
		space();
		
		if (match(TokenType.OpenParen)) {
			nextToken();
			auto guard = changeMode(Mode.Parameter);
			parseStructuralElement();
			runOnType!(TokenType.CloseParen, nextToken)();
		}
		
		space();
		return parseControlFlowBlock(indentLevel);
	}
	
	void emitBlockControlFlowWhitespace(bool isBlock) {
		clearSplitType();
		if (isBlock) {
			space();
		} else {
			newline(1);
		}
	}
	
	void parseIf() in {
		assert(match(TokenType.If));
	} body {
		bool isBlock = parseControlFlowBase();
		if (!match(TokenType.Else)) {
			return;
		}
		
		emitBlockControlFlowWhitespace(isBlock);
		parseElse();
	}
	
	void parseElse() in {
		assert(match(TokenType.Else));
	} body {
		space();
		nextToken();
		space();
		
		if (match(TokenType.If)) {
			parseIf();
		} else {
			parseControlFlowBlock();
		}
	}
	
	void parseWhile() in {
		assert(match(TokenType.While));
	} body {
		parseControlFlowBase();
	}
	
	void parseDoWhile() in {
		assert(match(TokenType.Do));
	} body {
		nextToken();
		space();
		bool isBlock = parseControlFlowBlock();
		
		if (!match(TokenType.While)) {
			return;
		}
		
		emitBlockControlFlowWhitespace(isBlock);
		nextToken();
		
		if (match(TokenType.OpenParen)) {
			nextToken();
			auto guard = changeMode(Mode.Parameter);
			parseStructuralElement();
			runOnType!(TokenType.CloseParen, nextToken)();
		}
		
		runOnType!(TokenType.Semicolon, nextToken)();
		newline(2);
	}
	
	void parseFor() in {
		assert(match(TokenType.For));
	} body {
		nextToken();
		space();
		
		if (match(TokenType.OpenParen)) {
			nextToken();
			if (match(TokenType.Semicolon)) {
				nextToken();
			} else {
				parseStructuralElement();
				clearSplitType();
			}
			
			if (match(TokenType.Semicolon)) {
				nextToken();
			} else {
				space();
				parseExpression();
				runOnType!(TokenType.Semicolon, nextToken)();
			}
			
			if (match(TokenType.CloseParen)) {
				nextToken();
			} else {
				space();
				parseExpression();
			}

			runOnType!(TokenType.CloseParen, nextToken)();
		}
		
		space();
		parseControlFlowBlock();
	}
	
	void parseForeach() in {
		assert(match(TokenType.Foreach) || match(TokenType.ForeachReverse));
	} body {
		nextToken();
		space();
		
		if (match(TokenType.OpenParen)) {
			nextToken();
			auto guard = changeMode(Mode.Parameter);
			
			parseList!parseStructuralElement(TokenType.Semicolon);
			
			space();
			parseList!parseExpression(TokenType.CloseParen);
		}
		
		space();
		parseControlFlowBlock();
	}
	
	void parseReturn() in {
		assert(match(TokenType.Return));
	} body {
		nextToken();
		space();
		parseExpression();
	}
	
	void parseSwitch() in {
		assert(match(TokenType.Switch));
	} body {
		parseControlFlowBase(2);
	}
	
	/**
	 * Types
	 */
	void parseType() {
		parseIdentifier();
		
		do {
			// '*' could be a pointer or a multiply, so it is not parsed eagerly.
			runOnType!(TokenType.Star, nextToken)();
		} while(parseIdentifierSuffix());
	}
	
	/**
	 * Expressions
	 */
	void parseExpression() {
		parseBaseExpression();
		parseBinaryExpression();
	}
	
	void parseBaseExpression() {
		parseIdentifier();
	}
	
	void parseBinaryExpression() {
		while (true) {
			switch (token.type) with(TokenType) {
				case Equal:
				case PlusEqual:
				case MinusEqual:
				case StarEqual:
				case SlashEqual:
				case PercentEqual:
				case AmpersandEqual:
				case PipeEqual:
				case CaretEqual:
				case TildeEqual:
				case LessLessEqual:
				case MoreMoreEqual:
				case MoreMoreMoreEqual:
				case CaretCaretEqual:
				case PipePipe:
				case AmpersandAmpersand:
				case Pipe:
				case Caret:
				case Ampersand:
				case EqualEqual:
				case BangEqual:
				case More:
				case MoreEqual:
				case Less:
				case LessEqual:
				case BangLessMoreEqual:
				case BangLessMore:
				case LessMore:
				case LessMoreEqual:
				case BangMore:
				case BangMoreEqual:
				case BangLess:
				case BangLessEqual:
				case Is:
				case In:
				case Bang:
				case LessLess:
				case MoreMore:
				case MoreMoreMore:
				case Plus:
				case Minus:
				case Tilde:
				case Slash:
				case Star:
				case Percent:
					space();
					nextToken();
					space();
					break;
				
				case QuestionMark:
					goto default;
				
				default:
					return;
			}
			
			parseBaseExpression();
		}
	}
	
	bool parseArgumentList() {
		return parseList!parseExpression();
	}
	
	/**
	 * Declarations
	 */
	void parseTypedDeclaration() in {
		assert(match(TokenType.Identifier));
	} body {
		bool loop = mode == Mode.Parameter;
		do {
			space();
			runOnType!(TokenType.Identifier, nextToken)();
			
			while (parseParameterList()) {}
			
			// Function declaration.
			if (match(TokenType.OpenBrace)) {
				space();
				parseBlock(Mode.Statement);
				return;
			}
			
			// Variable, template parameters, whatever.
			while (match(TokenType.Equal) || match(TokenType.Colon)) {
				space();
				nextToken();
				space();
				parseExpression();
			}
			
			if (!match(TokenType.Comma)) {
				break;
			}
			
			nextToken();
		} while (loop);
	}
	
	void parseConstructor() in {
		assert(match(TokenType.This));
	} body {
		nextToken();
		
		while (parseParameterList()) {}
		
		// Function declaration.
		if (match(TokenType.OpenBrace)) {
			space();
			parseBlock(Mode.Statement);
		}
	}
	
	bool parseParameterList() {
		auto guard = changeMode(Mode.Parameter);
		return parseList!parseStructuralElement();
	}
	
	void parseStorageClass() {
		while (true) {
			switch (token.type) with (TokenType) {
				case Abstract, Auto, Alias, Deprecated, Final, Nothrow, Override, Pure, Static:
				case Const, Immutable, Inout, Shared, __Gshared:
					nextToken();
					break;
				
				case Align, Extern, Scope, Synchronized:
					nextToken();
					parseArgumentList();
					space();
					break;
				
				default:
					return;
					
			}
			
			switch (token.type) with (TokenType) {
				case Colon:
					nextToken();
					newline(1);
					return;
					
				case OpenBrace:
					space();
					parseBlock(mode);
					return;
				
				case Identifier:
					auto lookahead = trange.save.withComments(false);
					lookahead.popFront();
					
					switch (lookahead.front.type) {
						case Equal:
						case OpenParen:
							parseTypedDeclaration();
							break;
						
						default:
							parseStructuralElement();
							break;
					}
					
					return;
				
				default:
					break;
			}
		}
	}
	
	void parseEnum() in {
		assert(match(TokenType.Enum));
	} body {
		nextToken();
		
		if (match(TokenType.Identifier)) {
			space();
			nextToken();
		}
		
		if (match(TokenType.Colon)) {
			space();
			nextToken();
			space();
			parseType();
		}
		
		if (match(TokenType.OpenBrace)) {
			space();
			nextToken();
			parseList!parseExpression(TokenType.CloseBrace, true);
		}
	}
	
	void parseAggregate() in {
		assert(
			match(TokenType.Struct) ||
			match(TokenType.Union) ||
			match(TokenType.Class) ||
			match(TokenType.Interface));
	} body {
		parseStorageClass();
		
		nextToken();
		space();
		
		runOnType!(TokenType.Identifier, nextToken)();
		
		parseArgumentList();
		space();
		
		if (match(TokenType.Colon)) {
			split();
			nextToken();
			space();
		}
		
		// TODO inheritance.
		
		parseBlock(Mode.Declaration);
	}
	
	void parseAlias() in {
		assert(match(TokenType.Alias));
	} body {
		nextToken();
		space();
		
		runOnType!(TokenType.Identifier, nextToken)();
		
		parseArgumentList();
		space();
		
		switch (token.type) with(TokenType) {
			case This:
				nextToken();
				break;
			
			case Equal:
				nextToken();
				space();
				parseExpression();
				break;
			
			default:
				break;
		}
	}
	
	/**
	 * Parsing utilities
	 */
	bool parseList(alias fun)() {
		TokenType closingTokenType;
		switch (token.type) with(TokenType) {
			case OpenParen:
				closingTokenType = CloseParen;
				break;
			
			case OpenBracket:
				closingTokenType = CloseBracket;
				break;
			
			default:
				return false;
		}
		
		nextToken();
		return parseList!fun(closingTokenType);
	}

	bool parseList(alias fun)(TokenType closingTokenType, bool addNewLines = false) {
		if (match(closingTokenType)) {
			nextToken();
			return true;
		}
		
		while (true) {
			auto guard = builder.indent();
			while (true) {
				if (addNewLines) {
					newline(1);
				} else {
					split();
				}
				
				fun();
				
				if (!match(TokenType.Comma)) {
					break;
				}
				
				nextToken();
				space();
			}
			
			if (!match(TokenType.DotDot)) {
				break;
			}
			
			space();
			nextToken();
			space();
		}
		
		if (match(closingTokenType)) {
			if (addNewLines) {
				newline(1);
			}
			
			nextToken();
		}
		
		if (addNewLines) {
			newline(2);
		}

		return true;
	}
}