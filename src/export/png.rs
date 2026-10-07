//! PNG encode/decode for the editor's RGBA8 output.
//!
//! Only RGBA8 is handled — the app is the only producer. Adapted from
//! classic-game-box's `src/library/png_codec.rs` (same contract, no library
//! error type).

use std::fmt;

/// Why an encode / decode failed.
#[derive(Debug)]
pub enum PngError {
    /// A zero width or height was requested.
    ZeroSize,
    /// The buffer was shorter than `width * height * 4`.
    ShortBuffer { expected: usize, got: usize },
    /// The decoder returned a format other than 8-bit RGBA.
    Unsupported,
    /// The `png` crate rejected the data.
    Png(String),
}

impl fmt::Display for PngError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ZeroSize => write!(f, "zero width or height"),
            Self::ShortBuffer { expected, got } => {
                write!(f, "expected {expected} bytes, got {got}")
            }
            Self::Unsupported => write!(f, "unsupported png (need 8-bit RGBA)"),
            Self::Png(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for PngError {}

/// Encode RGBA8 pixels as a PNG.
pub fn encode_rgba(width: u32, height: u32, rgba: &[u8]) -> Result<Vec<u8>, PngError> {
    if width == 0 || height == 0 {
        return Err(PngError::ZeroSize);
    }
    let expected = width as usize * height as usize * 4;
    if rgba.len() < expected {
        return Err(PngError::ShortBuffer {
            expected,
            got: rgba.len(),
        });
    }
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder
            .write_header()
            .map_err(|error| PngError::Png(error.to_string()))?;
        writer
            .write_image_data(&rgba[..expected])
            .map_err(|error| PngError::Png(error.to_string()))?;
    }
    Ok(out)
}

/// Decode a PNG back into tightly packed RGBA8 pixels.
pub fn decode_rgba(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), PngError> {
    let decoder = png::Decoder::new(bytes);
    let mut reader = decoder
        .read_info()
        .map_err(|error| PngError::Png(error.to_string()))?;
    let mut buffer = vec![0; reader.output_buffer_size()];
    let info = reader
        .next_frame(&mut buffer)
        .map_err(|error| PngError::Png(error.to_string()))?;
    if info.color_type != png::ColorType::Rgba || info.bit_depth != png::BitDepth::Eight {
        return Err(PngError::Unsupported);
    }
    buffer.truncate(info.buffer_size());
    Ok((info.width, info.height, buffer))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_image_round_trips_through_png() {
        let (width, height) = (4u32, 3u32);
        let mut rgba = vec![0u8; width as usize * height as usize * 4];
        for (index, byte) in rgba.iter_mut().enumerate() {
            *byte = (index % 251) as u8;
        }
        let png = encode_rgba(width, height, &rgba).unwrap();
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n", "a real PNG signature");
        let (w, h, decoded) = decode_rgba(&png).unwrap();
        assert_eq!((w, h), (width, height));
        assert_eq!(decoded, rgba);
    }

    #[test]
    fn a_short_buffer_is_rejected() {
        assert!(matches!(
            encode_rgba(2, 2, &[0, 0, 0, 0]),
            Err(PngError::ShortBuffer { .. })
        ));
    }

    #[test]
    fn a_zero_size_is_rejected() {
        assert!(matches!(encode_rgba(0, 5, &[]), Err(PngError::ZeroSize)));
    }
}
