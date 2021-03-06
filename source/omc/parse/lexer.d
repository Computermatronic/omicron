/* 
 * omc: The official Omicron compiler.
 * Reference implementation of the Omicron programming language.
 * Copyright (c) 2018-2021 by Sean Campbell.
 * Written by Sean Campbell.
 * Distributed under The MPL-2.0 license (See LICENCE file).
 */
module omc.parse.lexer;

public import omc.parse.token;
import std.algorithm;
import std.range;
import std.string;
import std.uni;
import omc.utils;

import std.stdio;

struct OmLexer {
	mixin ErrorSink;
	private {
		string buffer;
		OmToken lastToken;
		bool m_empty = true;
	}
	string name;
	string source;

	this(string name, string source) { 
		this.name = name;
		this.buffer = this.source = source;
		this.m_empty = !this.parseToken();
	}

	@property bool empty() { return m_empty; }

	@property typeof(this) save() { return this; }

	OmToken front() {
		if (empty) return OmToken(OmToken.Type.tk_eof, currentLocation, "<End of File>");
		return lastToken;
	}

	void popFront() {
		m_empty = !this.parseToken();
	}

	private {
		bool parseToken() {
			while(!buffer.empty) {
				if (buffer.front.isWhite) { buffer.popFront(); continue; }
				switch(buffer.take(2).array) {
					case `//`: parseLineComment(); continue;
					case `/*`: parseBlockComment(); continue;
					case `/+`: parseNestedBlockComment(); continue;
					default: break;
				}
				switch(buffer.take(1).array) {
					case `'`: lastToken = parseCharacter();  return true;
					case `"`: lastToken = parseString();  return true;
					case "`": lastToken = parseExactString();  return true;
					default: break;
				}
				if (buffer.front.isNumber) { lastToken = parseNumber(); return true; }
				foreach(tokenName; tokenNames) {
					auto takeN = buffer.take(tokenName.length + 1).array;
					auto lastN = takeN.length > tokenName.length ? takeN[$-1] : '\0';
					takeN = takeN.length > tokenName.length ? takeN[0..$-1] : takeN;
					if (tokenName.equal(takeN)) {
						if (!tokenName.all!isIdentifierChar || !lastN.isIdentifierChar) {
							auto location = currentLocation;
							buffer.popFrontN(tokenName.length);
							lastToken = OmToken(tokenLiterals[tokenName], location, tokenName);
							return true;
						}
					}
				}
				if (buffer.front.isIdentifierChar) { lastToken = parseIdentifier(); return true; }
				if (buffer.front == '@') { lastToken = parseAttribute(); return true; }
				error(currentLocation, "Unknown or illegal character '%s'.", buffer.front);
				lastToken = OmToken(OmToken.Type.ud_unknown, currentLocation, cast(string)[buffer.stealFront]);
				return true;
			}
			return false;
		}

		string parseLineComment() {
			buffer.popFrontN(2);
			auto end = buffer.indexOfAny("\r\n");
			end = end > 0 ? end : buffer.length;
			auto lexeme = buffer[0..end];
			buffer.popFrontN(end);
			return lexeme;
		}

		string parseBlockComment() {
			buffer.popFrontN(2);
			auto end = buffer.indexOf("*/");
			if (end == -1) {
				error(currentLocation, "Unterminated block comment.");
				auto lexeme = buffer;
				buffer.popFrontN(buffer.length);
				return lexeme;
			} else {
				auto lexeme = buffer[0..end];
				buffer.popFrontN(end + 2);
				return lexeme;
			}
		}

		string parseNestedBlockComment() {
			size_t nestingLevel = 1;
			string subBuffer = buffer;
			buffer.popFrontN(2);
			while(!subBuffer.empty && nestingLevel > 0) {
				auto result = subBuffer.take(2);
				if (result.equal(`/+`)) {
					subBuffer.popFrontN(2);
					nestingLevel++;
				} else if (result.equal(`+/`)) {
					subBuffer.popFrontN(2);
					nestingLevel--;
				} else subBuffer.popFront();
			}
			if (nestingLevel > 0) error(currentLocation, "Unterminated nested block comment.");
			auto end = buffer.length - subBuffer.length;
			auto lexeme = buffer[0..end];
			buffer.popFrontN(end);
			return lexeme;
		}

		OmToken parseString() {
			auto token = OmToken(OmToken.Type.ud_string, currentLocation);
			Appender!string result;
			buffer.popFront();
			while(!buffer.empty && buffer.front != '\"') {
				result.put(parseChar());
			}
			token.lexeme = result.data;
			if (buffer.empty) error(token.location, "Unterminated string constant.");
			else buffer.popFront();
			token.literal = token.lexeme;
			return token;
		}

		OmToken parseExactString() {
			auto token = OmToken(OmToken.Type.ud_string, currentLocation);
			buffer.popFront();
			auto end = buffer.indexOf("`");
			if (end == -1) {
				error(currentLocation, "Unterminated string literal.");
				token.lexeme = buffer;
				buffer.popFrontN(buffer.length);
			} else {
				token.lexeme = buffer[0..end];
				buffer.popFrontN(end + 1);
			}
			token.literal = token.lexeme;
			return token;
		}

		OmToken parseCharacter() {
			auto token = OmToken(OmToken.Type.ud_char, currentLocation);
			buffer.popFront();
			if (!buffer.empty) { token.lexeme = cast(string)[parseChar()]; token.literal = token.lexeme.front; }
			if (!buffer.empty) buffer.popFront();
			else error(currentLocation, "Unterminated character literal.");
			return token;
		}

		OmToken parseNumber() {
			auto token = OmToken(OmToken.Type.ud_integer, currentLocation);
			auto subBuffer = buffer;
			while(!subBuffer.empty && (subBuffer.front.isNumber || subBuffer.front == '.' || subBuffer.front == '_')) {
				if (subBuffer.front == '.' && token.type != OmToken.Type.ud_float) token.type = OmToken.Type.ud_float;
				else if (subBuffer.front == '.') break;
				subBuffer.popFront();
			}
			auto end = buffer.length - subBuffer.length;
			token.lexeme = buffer[0..end];
			if (token.type == OmToken.Type.ud_integer) token.literal = token.lexeme.parseInteger();
			else token.literal = token.lexeme.parseFloat();
			buffer.popFrontN(end);
			return token;
		}

		OmToken parseIdentifier() {
			auto token = OmToken(OmToken.Type.ud_identifier, currentLocation);
			auto subBuffer = buffer;
			while(!subBuffer.empty && (subBuffer.front.isIdentifierChar)) {
				subBuffer.popFront();
			}
			auto end = buffer.length - subBuffer.length;
			token.lexeme = buffer[0..end];
			buffer.popFrontN(end);
			return token;
		}

		OmToken parseAttribute() {
			auto token = OmToken(OmToken.Type.ud_attribute, currentLocation);
			buffer.popFront();
			auto subBuffer = buffer;
			while(!subBuffer.empty && (subBuffer.front.isIdentifierChar)) {
				subBuffer.popFront();
			}
			auto end = buffer.length - subBuffer.length;
			token.lexeme = buffer[0..end];
			buffer.popFrontN(end);
			return token;
		}

		dchar parseChar() {
			if (buffer.front == '\\') switch(buffer.take(2).array) {
				case `\\`: buffer.popFrontN(2); return '\\';
				case `\'`: buffer.popFrontN(2); return '\'';
				case `\"`: buffer.popFrontN(2); return '\"';
				case `\r`: buffer.popFrontN(2); return '\r';
				case `\n`: buffer.popFrontN(2); return '\n';
				case `\t`: buffer.popFrontN(2); return '\t';
				case `\0`: buffer.popFrontN(2); return '\0';
				default: error(currentLocation, "Unknown escape sequence %s", buffer.take(2).array);
			}
			auto c = buffer.front;
			buffer.popFront();
			return c;
		}

		@property OmSrcLocation currentLocation() {
			return OmSrcLocation.fromBuffer(source, source.length - buffer.length, name);
		}
	}
}

bool isIdentifierChar(dchar c) {
	return c == '$' || c == '_' ||  c.isAlphaNum();
}



long parseInteger(string s) {
	long result; bool isNegative;
	if (s.front == '-') { isNegative = true; s.popFront(); }
	foreach(c; s) {
		if(c == '_') continue;
		result *= 10;
		result += cast(ubyte)c - '0';
	}
	return isNegative ? -result : result;
}

double parseFloat(string s) {
	bool isNegative, isOnRhs;
	float rhs = 0;
	long lhs, dLen;
	if (s.front == '-') { isNegative = true; s.popFront(); }
	foreach(c; s) {
		if(c == '_') continue;
		if (!isOnRhs && c == '.') { isOnRhs = true; dLen = 1; continue; }
		if (isOnRhs) {
			rhs *= 10;
			rhs += cast(ubyte)c - '0';
			dLen *= 10;
		} else {
			lhs *= 10;
			lhs += cast(ubyte)c - '0';
		}
	}
	float result = lhs + (rhs / dLen);
	return isNegative ? -result : result;
}