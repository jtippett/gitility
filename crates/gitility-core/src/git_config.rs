//! The byte-oriented subset of Git's config parser used for `.gitmodules`.
//!
//! This intentionally follows the blob reader in Git 2.55.0 rather than
//! providing a general-purpose configuration API. In particular, the blob
//! reader promotes signed `char` values, so `0xff` is indistinguishable from
//! EOF and a UTF-8 BOM is rejected. Those oddities are compatibility
//! requirements for snapshot `.gitmodules` data.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ParseError {
    pub(crate) line: u32,
}

/// Parses `input`, visiting canonicalized keys in source order.
///
/// Section and variable names are ASCII-lowercased. A subsection written in
/// the modern quoted form keeps its case, while the legacy dotted form is
/// lowercased with the rest of its header. `None` is Git's implicit boolean
/// value; callers must not turn it into the bytes `true` unless their own
/// config consumer explicitly asks for boolean coercion.
pub(crate) fn parse(
    input: &[u8],
    mut visit: impl FnMut(&[u8], Option<&[u8]>),
) -> Result<(), ParseError> {
    Parser::new(input).parse(&mut visit)
}

struct Parser<'a> {
    input: &'a [u8],
    position: usize,
    line: u32,
    eof: bool,
    name: Vec<u8>,
    value: Vec<u8>,
    base_len: usize,
}

impl<'a> Parser<'a> {
    fn new(input: &'a [u8]) -> Self {
        Self {
            input,
            position: 0,
            line: 1,
            eof: false,
            name: Vec::new(),
            value: Vec::new(),
            base_len: 0,
        }
    }

    fn parse(&mut self, visit: &mut impl FnMut(&[u8], Option<&[u8]>)) -> Result<(), ParseError> {
        let mut comment = false;

        loop {
            let c = self.next_char();
            if c == i16::from(b'\n') {
                if self.eof {
                    return Ok(());
                }
                comment = false;
                continue;
            }
            if comment {
                continue;
            }
            if is_space(c) {
                continue;
            }
            if c == i16::from(b'#') || c == i16::from(b';') {
                comment = true;
                continue;
            }
            if c == i16::from(b'[') {
                self.name.clear();
                if self.parse_section_header().is_err() || self.name.is_empty() {
                    return Err(self.error());
                }
                self.name.push(b'.');
                self.base_len = self.name.len();
                continue;
            }
            if !is_alpha(c) {
                return Err(self.error());
            }

            self.name.truncate(self.base_len);
            self.name.push(ascii_lower(c as u8));
            if self.parse_entry(visit).is_err() {
                return Err(self.error());
            }
        }
    }

    fn parse_entry(&mut self, visit: &mut impl FnMut(&[u8], Option<&[u8]>)) -> Result<(), ()> {
        let mut c;
        loop {
            c = self.next_char();
            if self.eof || !is_key_char(c) {
                break;
            }
            self.name.push(ascii_lower(c as u8));
        }

        while c == i16::from(b' ') || c == i16::from(b'\t') {
            c = self.next_char();
        }

        let has_value = if c == i16::from(b'\n') {
            false
        } else {
            if c != i16::from(b'=') {
                return Err(());
            }
            self.parse_value()?;
            true
        };

        // Git passes C strings to its config callback. Embedded NUL bytes do
        // not end parsing, but they do truncate the key/value observed by the
        // consumer. Apply that truncation only after the full line validates.
        let name_len = c_string_len(&self.name);
        let value_len = c_string_len(&self.value);
        self.line = self.line.saturating_sub(1);
        visit(
            &self.name[..name_len],
            has_value.then_some(&self.value[..value_len]),
        );
        self.line = self.line.saturating_add(1);
        Ok(())
    }

    fn parse_value(&mut self) -> Result<(), ()> {
        let mut quoted = false;
        let mut comment = false;
        let mut trim_len = 0usize;
        self.value.clear();

        loop {
            let mut c = self.next_char();
            if c == i16::from(b'\n') {
                if quoted {
                    self.line = self.line.saturating_sub(1);
                    return Err(());
                }
                if trim_len != 0 {
                    self.value.truncate(trim_len);
                }
                return Ok(());
            }
            if comment {
                continue;
            }
            if is_space(c) && !quoted {
                if trim_len == 0 {
                    trim_len = self.value.len();
                }
                if !self.value.is_empty() {
                    self.value.push(c as u8);
                }
                continue;
            }
            if !quoted && (c == i16::from(b';') || c == i16::from(b'#')) {
                comment = true;
                continue;
            }
            if trim_len != 0 {
                trim_len = 0;
            }
            if c == i16::from(b'\\') {
                c = self.next_char();
                c = match c {
                    value if value == i16::from(b'\n') => continue,
                    value if value == i16::from(b't') => i16::from(b'\t'),
                    value if value == i16::from(b'b') => i16::from(8_u8),
                    value if value == i16::from(b'n') => i16::from(b'\n'),
                    value if value == i16::from(b'\\') || value == i16::from(b'"') => value,
                    _ => return Err(()),
                };
                self.value.push(c as u8);
                continue;
            }
            if c == i16::from(b'"') {
                quoted = !quoted;
                continue;
            }
            self.value.push(c as u8);
        }
    }

    fn parse_section_header(&mut self) -> Result<(), ()> {
        loop {
            let c = self.next_char();
            if self.eof {
                return Err(());
            }
            if c == i16::from(b']') {
                return Ok(());
            }
            if is_space(c) {
                return self.parse_quoted_subsection(c);
            }
            if !is_key_char(c) && c != i16::from(b'.') {
                return Err(());
            }
            self.name.push(ascii_lower(c as u8));
        }
    }

    fn parse_quoted_subsection(&mut self, mut c: i16) -> Result<(), ()> {
        loop {
            if c == i16::from(b'\n') {
                self.line = self.line.saturating_sub(1);
                return Err(());
            }
            c = self.next_char();
            if !is_space(c) {
                break;
            }
        }

        if c != i16::from(b'"') {
            return Err(());
        }
        self.name.push(b'.');

        loop {
            c = self.next_char();
            if c == i16::from(b'\n') {
                self.line = self.line.saturating_sub(1);
                return Err(());
            }
            if c == i16::from(b'"') {
                break;
            }
            if c == i16::from(b'\\') {
                c = self.next_char();
                if c == i16::from(b'\n') {
                    self.line = self.line.saturating_sub(1);
                    return Err(());
                }
            }
            self.name.push(c as u8);
        }

        if self.next_char() != i16::from(b']') {
            return Err(());
        }
        Ok(())
    }

    /// Mirrors `config_buf_fgetc()` and `get_next_char()` from Git 2.55.0.
    fn next_char(&mut self) -> i16 {
        let mut c = self.raw_char();
        if c == i16::from(b'\r') {
            c = self.raw_char();
            if c != i16::from(b'\n') {
                if c != -1 {
                    self.position -= 1;
                }
                c = i16::from(b'\r');
            }
        }

        if c == i16::from(b'\n') {
            self.line = self.line.saturating_add(1);
        }
        if c == -1 {
            self.eof = true;
            self.line = self.line.saturating_add(1);
            c = i16::from(b'\n');
        }
        c
    }

    /// Git's in-memory blob reader returns a plain `char` as `int`. On the
    /// pinned Darwin build `char` is signed, making byte `0xff` equal EOF.
    fn raw_char(&mut self) -> i16 {
        let Some(byte) = self.input.get(self.position).copied() else {
            return -1;
        };
        self.position += 1;
        i16::from(byte as i8)
    }

    fn error(&self) -> ParseError {
        ParseError { line: self.line }
    }
}

fn c_string_len(bytes: &[u8]) -> usize {
    bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len())
}

fn is_alpha(c: i16) -> bool {
    (i16::from(b'a')..=i16::from(b'z')).contains(&c)
        || (i16::from(b'A')..=i16::from(b'Z')).contains(&c)
}

fn is_key_char(c: i16) -> bool {
    is_alpha(c) || (i16::from(b'0')..=i16::from(b'9')).contains(&c) || c == i16::from(b'-')
}

fn is_space(c: i16) -> bool {
    matches!(c, 9 | 10 | 13 | 32)
}

fn ascii_lower(byte: u8) -> u8 {
    if byte.is_ascii_uppercase() {
        byte + (b'a' - b'A')
    } else {
        byte
    }
}

#[cfg(test)]
mod oracle_tests;
