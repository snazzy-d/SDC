module sdc.format.chunk;

enum SplitType {
	None,
	Space,
	NewLine,
	TwoNewLines,
}

enum ChunkKind {
	Text,
	Block,
}

final class Span {
	Span parent = null;
	uint cost = 1;
	uint indent = 1;
	
	this(Span parent, uint cost, uint indent) {
		this.parent = parent;
		this.cost = cost;
		this.indent = indent;
	}
	
	// lhs < rhs => rhs.opCmp(rhs) < 0
	int opCmp(const Span rhs) const {
		auto lhsPtr = cast(void*) this;
		auto rhsPtr = cast(void*) rhs;
		
		return (lhsPtr > rhsPtr) - (lhsPtr < rhsPtr);
	}
	
	static string print(const Span span) {
		if (span is null)  {
			return "null";
		}
		
		return span.toString();
	}
	
	override string toString() const {
		import std.conv;
		return "Span(" ~ print(parent) ~ ", " ~ cost.to!string ~ ", " ~ indent.to!string ~ ")";
	}
}

struct Chunk {
private:
	import util.bitfields, std.typetuple;
	alias FieldsTuple = TypeTuple!(
		// sdfmt off
		ChunkKind, "_kind", EnumSize!ChunkKind,
		SplitType, "_splitType", EnumSize!SplitType,
		uint, "_indentation", 10,
		uint, "_length", 16,
		// sdfmt on
	);
	
	enum Pad = ulong.sizeof * 8 - SizeOfBitField!FieldsTuple;
	
	import std.bitmanip;
	mixin(bitfields!(FieldsTuple, ulong, "", Pad));
	
	union {
		string _text;
		Chunk[] _chunks;
	}
	
public:
	Span span = null;
	
	@property
	ChunkKind kind() const {
		return _kind;
	}
	
	@property
	SplitType splitType() const {
		return _splitType;
	}
	
	@property
	SplitType splitType(SplitType st) {
		_splitType = st;
		return splitType;
	}
	
	@property
	uint indentation() const {
		return _indentation;
	}
	
	@property
	uint indentation(uint i) {
		_indentation = i;
		return i;
	}
	
	@property
	uint length() const {
		return _length;
	}
	
	@property
	bool empty() const {
		return kind ? chunks.length == 0 : text.length == 0;
	}
	
	@property
	ref inout(string) text() inout in {
		assert(kind == ChunkKind.Text);
	} body {
		return _text;
	}
	
	@property
	const(Chunk)[] chunks() const in {
		assert(kind == ChunkKind.Block);
	} body {
		return _chunks;
	}
	
	bool endsBreakableLine() const {
		return span is null && (splitType == SplitType.NewLine || splitType == SplitType.TwoNewLines);
	}
	
	string toString() const {
		import std.conv;
		return "Chunk(" ~ splitType.to!string ~ ", "
			~ Span.print(span) ~ ", "
			~ indentation.to!string ~ ", "
			~ length.to!string ~ ", "
			~ (kind ? chunks.to!string : [text].to!string) ~ ")";
	}
}

struct Builder {
public:
	Chunk chunk;
	Chunk[] source;
	
	SplitType pendingWhiteSpace = SplitType.None;
	uint indentation;
	
	Span spanStack = null;
	
public:
	Chunk[] build() {
		split();
		return source;
	}
	
	/**
	 * Write into the next chunk.
	 */
	void write(string s) {
		emitPendingWhiteSpace();
		
		import std.stdio;
		// writeln("write: ", [s]);
		chunk.text ~= s;
	}
	
	void space() {
		import std.stdio;
		// writeln("space!");
		setWhiteSpace(SplitType.Space);
	}
	
	void newline(int nLines = 1) {
		import std.stdio;
		// writeln("newline ", nLines);
		setWhiteSpace(nLines > 1 ? SplitType.TwoNewLines : SplitType.NewLine);
	}
	
	void clearSplitType() {
		import std.stdio;
		// writeln("clearSplitType!");
		pendingWhiteSpace = SplitType.None;
	}
	
	void split() {
		import std.stdio;
		// writeln("split!");

		scope(success) {
			chunk.indentation = indentation;
			chunk.span = spanStack;
		}
		
		uint nlCount = 0;
		
		size_t last = chunk.text.length;
		while (last > 0) {
			char lastChar = chunk.text[last - 1];
			
			import std.ascii;
			if (!isWhite(lastChar)) {
				break;
			}
			
			last--;
			if (lastChar == ' ') {
				space();
			}
			
			if (lastChar == '\n') {
				nlCount++;
			}
		}
		
		if (nlCount) {
			newline(nlCount);
		}
		
		chunk.text = chunk.text[0 .. last];
		
		// There is nothing to flush.
		if (chunk.empty) {
			return;
		}
		
		import std.uni, std.range;
		chunk._length = cast(uint) chunk.text.byGrapheme.walkLength();
		
		source ~= chunk;
		chunk = Chunk();
		
		// TODO: Process rules.
	}
	
	auto indent(uint level = 1) {
		static struct Guard {
			~this() {
				builder.indentation = oldLevel;
			}
			
		private:
			Builder* builder;
			uint oldLevel;
		}
		
		uint oldLevel = indentation;
		indentation += level;
		
		return Guard(&this, oldLevel);
	}
	
	auto unindent(uint level = 1) {
		import std.algorithm;
		level = min(level, indentation);
		return indent(-level);
	}
	
	/**
	 * Span management.
	 */
	auto span(uint cost = 1, uint indent = 1) {
		emitPendingWhiteSpace();
		
		static struct Guard {
			~this() {
				assert(builder.spanStack is span);
				builder.spanStack = span.parent;
			}
			
		private:
			Builder* builder;
			Span span;
		}
		
		spanStack = new Span(spanStack, cost, indent);
		return Guard(&this, spanStack);
	}
	
	bool spliceSpan() {
		Span parent = spanStack.parent;
		Span insert;
		
		import std.range;
		foreach (ref c; only(chunk).chain(source.retro())) {
			if (c.span !is parent) {
				insert = c.span;
				break;
			}
			
			c.span = spanStack;
		}
		
		while (insert !is null && insert.parent !is parent) {
			insert = insert.parent;
		}
		
		bool doSlice = insert !is null && insert !is spanStack;
		if (doSlice) {
			insert.parent = spanStack;
		}
		
		return doSlice;
	}
	
private:
	void setWhiteSpace(SplitType st) {
		import std.algorithm;
		pendingWhiteSpace = max(pendingWhiteSpace, st);
	}
	
	void emitPendingWhiteSpace() {
		scope(success) {
			import std.algorithm;
			chunk.splitType = max(chunk.splitType, pendingWhiteSpace);
			
			pendingWhiteSpace = SplitType.None;
		}
		
		final switch (pendingWhiteSpace) with (SplitType) {
			case None:
				// nothing to do.
				return;
			
			case Space:
				if (!chunk.empty) {
					chunk.text ~= ' ';
					pendingWhiteSpace = SplitType.None;
				}
				return;
			
			case NewLine, TwoNewLines:
				split();
		}
	}
}
