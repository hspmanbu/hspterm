//! Versioned streaming backup envelope. Only ciphertext reaches disk. KDF cost
//! is fixed by the format, never read from attacker-controlled cost parameters.
use aes_gcm::{
    KeyInit, Nonce,
    aead::{Aead, Payload},
};
use rand::{RngCore, rngs::OsRng};
use std::io::{self, Read, Write};
use zeroize::{Zeroize, Zeroizing};

const MAGIC: &[u8; 8] = b"HSPBKP01";
const HEADER: usize = 32;
const CHUNK: usize = 1024 * 1024;
pub(super) const MAX_PLAIN: usize = 256 * 1024 * 1024;
pub(super) const MAX_CIPHER: u64 = MAX_PLAIN as u64 + 1024 * 1024;
fn invalid() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "备份密码错误、格式不支持或数据损坏",
    )
}
fn nonce(header: &[u8; HEADER], sequence: u32) -> [u8; 12] {
    let mut value = [0; 12];
    value[..8].copy_from_slice(&header[24..]);
    value[8..].copy_from_slice(&sequence.to_be_bytes());
    value
}
fn aad(header: &[u8; HEADER], sequence: u32, length: u32) -> Vec<u8> {
    let mut value = header.to_vec();
    value.extend_from_slice(&sequence.to_be_bytes());
    value.extend_from_slice(&length.to_be_bytes());
    value
}
fn cipher(header: &[u8; HEADER], password: &[u8]) -> io::Result<crate::VaultCipher> {
    if password.is_empty() || password.len() > 4096 {
        return Err(invalid());
    }
    let key = crate::derive(password, &header[8..24]).map_err(|_| invalid())?;
    crate::VaultCipher::new_from_slice(key.as_ref()).map_err(|_| invalid())
}
pub(super) struct EncryptedWriter<W: Write> {
    writer: W,
    cipher: crate::VaultCipher,
    header: [u8; HEADER],
    buffer: Zeroizing<Vec<u8>>,
    sequence: u32,
    total: usize,
}
impl<W: Write> EncryptedWriter<W> {
    pub fn new(mut writer: W, password: &[u8]) -> io::Result<Self> {
        let mut header = [0; HEADER];
        header[..8].copy_from_slice(MAGIC);
        OsRng.fill_bytes(&mut header[8..]);
        let cipher = cipher(&header, password)?;
        writer.write_all(&header)?;
        Ok(Self {
            writer,
            cipher,
            header,
            buffer: Zeroizing::new(Vec::with_capacity(CHUNK)),
            sequence: 0,
            total: 0,
        })
    }
    fn frame(&mut self, final_frame: bool) -> io::Result<()> {
        let mut plain = Zeroizing::new(Vec::with_capacity(self.buffer.len() + 1));
        plain.push(u8::from(final_frame));
        plain.extend_from_slice(&self.buffer);
        let length = u32::try_from(plain.len() + 16).map_err(|_| invalid())?;
        let encrypted = self
            .cipher
            .encrypt(
                Nonce::from_slice(&nonce(&self.header, self.sequence)),
                Payload {
                    msg: &plain,
                    aad: &aad(&self.header, self.sequence, length),
                },
            )
            .map_err(|_| invalid())?;
        self.writer.write_all(&length.to_be_bytes())?;
        self.writer.write_all(&encrypted)?;
        self.sequence = self.sequence.checked_add(1).ok_or_else(invalid)?;
        self.buffer.zeroize();
        self.buffer.clear();
        Ok(())
    }
    pub fn finish(mut self) -> io::Result<W> {
        self.frame(true)?;
        self.writer.flush()?;
        Ok(self.writer)
    }
}
impl<W: Write> Write for EncryptedWriter<W> {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        let n = data.len().min(CHUNK - self.buffer.len());
        if self.total.checked_add(n).is_none_or(|n| n > MAX_PLAIN) {
            return Err(invalid());
        }
        self.buffer.extend_from_slice(&data[..n]);
        self.total += n;
        if self.buffer.len() == CHUNK {
            self.frame(false)?;
        }
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.writer.flush()
    }
}

pub(super) struct EncryptedReader<R: Read> {
    reader: R,
    cipher: crate::VaultCipher,
    header: [u8; HEADER],
    buffer: Zeroizing<Vec<u8>>,
    offset: usize,
    sequence: u32,
    total: usize,
    final_frame: bool,
}
impl<R: Read> EncryptedReader<R> {
    pub fn new(mut reader: R, password: &[u8]) -> io::Result<Self> {
        let mut header = [0; HEADER];
        reader.read_exact(&mut header)?;
        if &header[..8] != MAGIC {
            return Err(invalid());
        }
        let cipher = cipher(&header, password)?;
        Ok(Self {
            reader,
            cipher,
            header,
            buffer: Zeroizing::new(Vec::new()),
            offset: 0,
            sequence: 0,
            total: 0,
            final_frame: false,
        })
    }
    fn next(&mut self) -> io::Result<()> {
        let mut length = [0; 4];
        self.reader.read_exact(&mut length)?;
        let length = u32::from_be_bytes(length);
        if !(17..=CHUNK as u32 + 17).contains(&length)
            || self.sequence > (MAX_PLAIN / CHUNK + 1) as u32
        {
            return Err(invalid());
        }
        let mut encrypted = vec![0; length as usize];
        self.reader.read_exact(&mut encrypted)?;
        let plain = self
            .cipher
            .decrypt(
                Nonce::from_slice(&nonce(&self.header, self.sequence)),
                Payload {
                    msg: &encrypted,
                    aad: &aad(&self.header, self.sequence, length),
                },
            )
            .map_err(|_| invalid())?;
        let plain = Zeroizing::new(plain);
        if plain[0] > 1 || (plain[0] == 0 && plain.len() != CHUNK + 1) {
            return Err(invalid());
        }
        self.final_frame = plain[0] == 1;
        self.total = self
            .total
            .checked_add(plain.len() - 1)
            .ok_or_else(invalid)?;
        if self.total > MAX_PLAIN {
            return Err(invalid());
        }
        self.sequence = self.sequence.checked_add(1).ok_or_else(invalid)?;
        self.buffer.zeroize();
        self.buffer.clear();
        self.buffer.extend_from_slice(&plain[1..]);
        self.offset = 0;
        if self.final_frame {
            let mut extra = [0; 1];
            if self.reader.read(&mut extra)? != 0 {
                return Err(invalid());
            }
        }
        Ok(())
    }
}
impl<R: Read> Read for EncryptedReader<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        if self.offset == self.buffer.len() {
            if self.final_frame {
                return Ok(0);
            }
            self.next()?;
        }
        let n = out.len().min(self.buffer.len() - self.offset);
        out[..n].copy_from_slice(&self.buffer[self.offset..self.offset + n]);
        self.offset += n;
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn envelope_authenticates_order_eof_password_and_chunk_boundaries() {
        let data = vec![0x71; CHUNK + 19];
        let mut writer = EncryptedWriter::new(Vec::new(), b"synthetic-backup-secret").unwrap();
        writer.write_all(&data).unwrap();
        let encrypted = writer.finish().unwrap();
        let mut reader =
            EncryptedReader::new(encrypted.as_slice(), b"synthetic-backup-secret").unwrap();
        let mut decoded = Vec::new();
        reader.read_to_end(&mut decoded).unwrap();
        assert_eq!(decoded, data);
        assert!(!encrypted.windows(32).any(|w| w == [0x71; 32]));
        let mut wrong =
            EncryptedReader::new(encrypted.as_slice(), b"synthetic-wrong-secret").unwrap();
        assert!(wrong.read_to_end(&mut Vec::new()).is_err());
        for kind in 0..4 {
            let mut bad = encrypted.clone();
            match kind {
                0 => bad[HEADER + 8] ^= 1,
                1 => {
                    bad.pop();
                }
                2 => bad.push(0),
                _ => {
                    let n = 4 + CHUNK + 17;
                    bad.drain(HEADER..HEADER + n);
                }
            }
            let mut reader =
                EncryptedReader::new(bad.as_slice(), b"synthetic-backup-secret").unwrap();
            assert!(reader.read_to_end(&mut Vec::new()).is_err());
        }
    }
}
