//! Metadata-free previews. Original downloads deliberately do not use this path.
use std::io::Cursor;

use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, metadata::Orientation};
use moxcms::{ColorProfile, DataColorSpace, Layout, ParsingOptions, TransformOptions};

const MAX_DECODE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_ICC_BYTES: usize = 4 * 1024 * 1024;
const MAX_PIXELS: u64 = 64 * 1024 * 1024;

/// Decode, orient, normalize ICC colors to sRGB, and encode only pixels.
/// No source metadata is copied, and no plaintext file is created.
pub(crate) fn sanitize_hidden_photo(bytes: &[u8]) -> Result<Vec<u8>, String> {
    if bytes.len() as u64 > MAX_DECODE_BYTES {
        return Err("hidden photo exceeds preview input limit".to_string());
    }
    let format = image::guess_format(bytes).map_err(|e| format!("preview format: {e}"))?;
    if !matches!(format, ImageFormat::Jpeg | ImageFormat::Png) {
        return Err("hidden photo preview supports static JPEG and PNG only".to_string());
    }
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(MAX_DECODE_BYTES);
    limits.max_image_width = Some(16384);
    limits.max_image_height = Some(16384);
    let (declared_icc, png_orientation) = if format == ImageFormat::Png {
        let (has_icc, orientation) = check_png_color_tags(bytes)?;
        let png = image::codecs::png::PngDecoder::with_limits(Cursor::new(bytes), limits.clone())
            .map_err(|e| format!("preview PNG: {e}"))?;
        if png
            .is_apng()
            .map_err(|e| format!("preview animation: {e}"))?
        {
            return Err("animated PNG cannot be used as a hidden photo preview".to_string());
        }
        (has_icc, Some(orientation))
    } else {
        (jpeg_declares_icc(bytes)?, None)
    };
    let mut reader = ImageReader::with_format(Cursor::new(bytes), format);
    reader.limits(limits);
    let mut decoder = reader
        .into_decoder()
        .map_err(|e| format!("preview decode: {e}"))?;
    let (width, height) = decoder.dimensions();
    if width == 0
        || height == 0
        || u64::from(width) * u64::from(height) > MAX_PIXELS
        || decoder.total_bytes() > MAX_DECODE_BYTES
    {
        return Err("hidden photo exceeds preview pixel limit".to_string());
    }
    let orientation = match png_orientation {
        Some(orientation) => orientation,
        None => decoder
            .orientation()
            .map_err(|e| format!("preview orientation: {e}"))?,
    };
    let icc = decoder
        .icc_profile()
        .map_err(|e| format!("preview ICC: {e}"))?;
    if declared_icc && icc.is_none() {
        return Err("hidden photo ICC could not be decoded".to_string());
    }
    if icc.as_ref().is_some_and(|p| p.len() > MAX_ICC_BYTES) {
        return Err("hidden photo ICC exceeds preview profile limit".to_string());
    }
    let mut pixels =
        DynamicImage::from_decoder(decoder).map_err(|e| format!("preview pixels: {e}"))?;
    pixels.apply_orientation(orientation);
    if let Some(icc) = icc {
        pixels = normalize_icc(pixels, &icc)?;
    }
    let mut output = Vec::new();
    pixels
        .write_with_encoder(image::codecs::png::PngEncoder::new(&mut output))
        .map_err(|e| format!("preview PNG encode: {e}"))?;
    Ok(output)
}

/// Inspect JPEG header segments before SOS. The decoder returns None for some
/// malformed multipart ICC profiles; that must not be mistaken for untagged sRGB.
fn jpeg_declares_icc(bytes: &[u8]) -> Result<bool, String> {
    if !bytes.starts_with(&[0xff, 0xd8]) {
        return Err("invalid preview JPEG signature".into());
    }
    let mut offset = 2usize;
    let mut declared = false;
    let mut expected_count = None;
    let mut seen = [false; 256];
    let mut fragment_count = 0usize;
    let mut profile_bytes = 0usize;
    while offset < bytes.len() {
        if bytes[offset] != 0xff {
            return Err("invalid preview JPEG marker".into());
        }
        while bytes.get(offset) == Some(&0xff) {
            offset += 1;
        }
        let marker = *bytes.get(offset).ok_or("truncated preview JPEG marker")?;
        offset += 1;
        if marker == 0xda || marker == 0xd9 {
            if expected_count.is_some_and(|count| fragment_count != usize::from(count)) {
                return Err("incomplete preview JPEG ICC fragments".into());
            }
            return Ok(declared);
        }
        if matches!(marker, 0x01 | 0xd0..=0xd7) {
            continue;
        }
        let length_bytes = bytes
            .get(offset..offset + 2)
            .ok_or("truncated preview JPEG length")?;
        let length = u16::from_be_bytes(length_bytes.try_into().unwrap()) as usize;
        if length < 2 {
            return Err("invalid preview JPEG segment length".into());
        }
        let end = offset
            .checked_add(length)
            .ok_or("preview JPEG segment overflow")?;
        let data = bytes
            .get(offset + 2..end)
            .ok_or("truncated preview JPEG segment")?;
        if marker == 0xe2 && data.starts_with(b"ICC_PROFILE") {
            if data.len() <= 14 || !data.starts_with(b"ICC_PROFILE\0") {
                return Err("invalid preview JPEG ICC fragment".into());
            }
            declared = true;
            let (sequence, count) = (data[12], data[13]);
            if sequence == 0
                || count == 0
                || sequence > count
                || seen[usize::from(sequence)]
                || expected_count.is_some_and(|expected| expected != count)
            {
                return Err("invalid preview JPEG ICC sequence".into());
            }
            expected_count = Some(count);
            seen[usize::from(sequence)] = true;
            fragment_count += 1;
            profile_bytes += data.len() - 14;
            if profile_bytes > MAX_ICC_BYTES {
                return Err("hidden photo ICC exceeds preview profile limit".into());
            }
        }
        offset = end;
    }
    Err("missing preview JPEG scan".into())
}

/// Inspect all chunks, including those after IDAT, before decoding pixels.
/// ICC and explicit sRGB take precedence over legacy gAMA/cHRM descriptors.
fn check_png_color_tags(bytes: &[u8]) -> Result<(bool, Orientation), String> {
    if !bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err("invalid preview PNG signature".to_string());
    }
    let mut offset = 8usize;
    let mut has_icc = false;
    let mut has_srgb = false;
    let mut exif_seen = false;
    let mut orientation = Orientation::NoTransforms;
    let mut gamma = None;
    let mut chromaticities = None;
    let mut cicp = None;
    let mut ended = false;
    while offset < bytes.len() {
        let header_end = offset.checked_add(8).ok_or("preview PNG chunk overflow")?;
        if header_end > bytes.len() {
            return Err("truncated preview PNG chunk".into());
        }
        let length = u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
        let end = header_end
            .checked_add(length)
            .and_then(|end| end.checked_add(4))
            .ok_or("preview PNG chunk overflow")?;
        if end > bytes.len() {
            return Err("truncated preview PNG chunk data".into());
        }
        let kind = &bytes[offset + 4..header_end];
        let data = &bytes[header_end..end - 4];
        match kind {
            b"eXIf" => {
                if exif_seen {
                    return Err("duplicate preview PNG EXIF".into());
                }
                exif_seen = true;
                let expected_crc = u32::from_be_bytes(bytes[end - 4..end].try_into().unwrap());
                if png_crc(&bytes[offset + 4..end - 4]) != expected_crc {
                    return Err("invalid preview PNG EXIF checksum".into());
                }
                // eXIf can legally follow IDAT; the decoder's initial metadata
                // view stops at IDAT and would silently miss that orientation.
                orientation =
                    Orientation::from_exif_chunk(data).unwrap_or(Orientation::NoTransforms);
            }
            b"iCCP" => {
                if has_icc {
                    return Err("duplicate preview PNG ICC".into());
                }
                has_icc = true;
            }
            b"sRGB" => {
                if has_srgb || data.len() != 1 || data[0] > 3 {
                    return Err("invalid preview PNG sRGB tag".into());
                }
                has_srgb = true;
            }
            b"gAMA" => {
                if gamma.is_some() || data.len() != 4 {
                    return Err("invalid preview PNG gamma tag".into());
                }
                gamma = Some(u32::from_be_bytes(data.try_into().unwrap()));
            }
            b"cHRM" => {
                if chromaticities.is_some() || data.len() != 32 {
                    return Err("invalid preview PNG chromaticities".into());
                }
                let mut values = [0u32; 8];
                for (value, encoded) in values.iter_mut().zip(data.as_chunks::<4>().0.iter()) {
                    *value = u32::from_be_bytes(*encoded);
                }
                chromaticities = Some(values);
            }
            b"cICP" => {
                if cicp.is_some() || data.len() != 4 {
                    return Err("invalid preview PNG cICP tag".into());
                }
                cicp = Some(data.to_vec());
            }
            b"IEND" => {
                if !data.is_empty() || end != bytes.len() {
                    return Err("invalid preview PNG end".into());
                }
                ended = true;
                break;
            }
            _ => {}
        }
        offset = end;
    }
    if !ended {
        return Err("missing preview PNG end".into());
    }
    if has_icc && (has_srgb || cicp.is_some()) {
        return Err("conflicting hidden photo PNG color profiles".into());
    }
    // cICP takes precedence even over ICC; only the sRGB RGB/full-range tuple is supported.
    if cicp.as_deref().is_some_and(|value| value != [1, 13, 0, 1]) {
        return Err("unsupported hidden photo PNG cICP color space".into());
    }
    if !has_icc
        && !has_srgb
        && cicp.is_none()
        && (gamma.is_some_and(|value| value != 45455)
            || chromaticities.is_some_and(|value| {
                value != [31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000]
            }))
    {
        return Err("unsupported hidden photo PNG gamma or chromaticities".into());
    }
    Ok((has_icc, orientation))
}

fn png_crc(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb88320 & (0u32.wrapping_sub(crc & 1)));
        }
    }
    !crc
}

fn normalize_icc(pixels: DynamicImage, icc: &[u8]) -> Result<DynamicImage, String> {
    let source = ColorProfile::new_from_slice_with_options(
        icc,
        ParsingOptions {
            max_profile_size: MAX_ICC_BYTES,
            max_allowed_clut_size: MAX_ICC_BYTES,
            max_allowed_trc_size: 40_000,
        },
    )
    .map_err(|e| format!("invalid preview ICC: {e}"))?;
    let target = ColorProfile::new_srgb();
    let (width, height) = (pixels.width(), pixels.height());
    let layout = match pixels.color() {
        image::ColorType::Rgb8 | image::ColorType::Rgb16 => Layout::Rgb,
        image::ColorType::Rgba8 | image::ColorType::Rgba16 => Layout::Rgba,
        image::ColorType::L8 | image::ColorType::L16 => Layout::Gray,
        image::ColorType::La8 | image::ColorType::La16 => Layout::GrayAlpha,
        _ => return Err("unsupported hidden photo ICC pixel format".to_string()),
    };
    let expected = match layout {
        Layout::Rgb | Layout::Rgba => DataColorSpace::Rgb,
        _ => DataColorSpace::Gray,
    };
    if source.color_space != expected {
        return Err("hidden photo ICC does not match decoded color space".to_string());
    }
    // Work by row so normalization needs only one additional image allocation.
    // 16-bit PNG samples retain their precision throughout the transform.
    macro_rules! convert {
        ($buffer:expr, $method:ident, $sample:ty, $variant:ident) => {{
            let buffer = $buffer;
            if u64::from(width) * u64::from(height) * 4 * std::mem::size_of::<$sample>() as u64
                > MAX_DECODE_BYTES
            {
                return Err("hidden photo exceeds normalized preview allocation limit".to_string());
            }
            let transform = source
                .$method(layout, &target, Layout::Rgba, TransformOptions::default())
                .map_err(|e| format!("preview ICC transform: {e}"))?;
            let mut output =
                image::ImageBuffer::<image::Rgba<$sample>, Vec<$sample>>::new(width, height);
            let input_stride = buffer.as_raw().len() / height as usize;
            let output_stride = width as usize * 4;
            for (input, output) in buffer
                .as_raw()
                .chunks_exact(input_stride)
                .zip(output.as_mut().chunks_exact_mut(output_stride))
            {
                transform
                    .transform(input, output)
                    .map_err(|e| format!("preview ICC pixels: {e}"))?;
            }
            DynamicImage::$variant(output)
        }};
    }
    Ok(match pixels {
        DynamicImage::ImageRgb8(b) => convert!(b, create_transform_8bit, u8, ImageRgba8),
        DynamicImage::ImageRgba8(b) => convert!(b, create_transform_8bit, u8, ImageRgba8),
        DynamicImage::ImageLuma8(b) => convert!(b, create_transform_8bit, u8, ImageRgba8),
        DynamicImage::ImageLumaA8(b) => convert!(b, create_transform_8bit, u8, ImageRgba8),
        DynamicImage::ImageRgb16(b) => convert!(b, create_transform_16bit, u16, ImageRgba16),
        DynamicImage::ImageRgba16(b) => convert!(b, create_transform_16bit, u16, ImageRgba16),
        DynamicImage::ImageLuma16(b) => convert!(b, create_transform_16bit, u16, ImageRgba16),
        DynamicImage::ImageLumaA16(b) => convert!(b, create_transform_16bit, u16, ImageRgba16),
        _ => return Err("unsupported hidden photo ICC pixel format".to_string()),
    })
}

/// A real JPEG with synthetic GPS EXIF and a 90-degree orientation.
#[cfg(test)]
pub(crate) fn gps_jpeg() -> Vec<u8> {
    use image::ImageEncoder;
    let mut tiff = Vec::from(&b"II\x2a\x00\x08\x00\x00\x00"[..]);
    fn entry(out: &mut Vec<u8>, tag: u16, kind: u16, count: u32, value: u32) {
        out.extend_from_slice(&tag.to_le_bytes());
        out.extend_from_slice(&kind.to_le_bytes());
        out.extend_from_slice(&count.to_le_bytes());
        out.extend_from_slice(&value.to_le_bytes());
    }
    tiff.extend_from_slice(&2u16.to_le_bytes());
    entry(&mut tiff, 0x0112, 3, 1, 6);
    entry(&mut tiff, 0x8825, 4, 1, 38);
    tiff.extend_from_slice(&0u32.to_le_bytes());
    tiff.extend_from_slice(&4u16.to_le_bytes());
    entry(&mut tiff, 1, 2, 2, u32::from(b'N'));
    entry(&mut tiff, 2, 5, 3, 92);
    entry(&mut tiff, 3, 2, 2, u32::from(b'E'));
    entry(&mut tiff, 4, 5, 3, 116);
    tiff.extend_from_slice(&0u32.to_le_bytes());
    for value in [12u32, 34, 56, 77, 45, 30] {
        tiff.extend_from_slice(&value.to_le_bytes());
        tiff.extend_from_slice(&1u32.to_le_bytes());
    }
    assert_eq!(tiff.len(), 140);
    let pixels = image::RgbImage::from_fn(40, 20, |x, _| {
        if x < 20 {
            image::Rgb([240, 20, 30])
        } else {
            image::Rgb([10, 220, 40])
        }
    });
    let mut output = Vec::new();
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut output, 95);
    encoder.set_exif_metadata(tiff).expect("fixture EXIF");
    encoder.encode_image(&pixels).expect("fixture JPEG");
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::ImageEncoder;

    fn assert_no_metadata(bytes: &[u8]) {
        let mut decoder = ImageReader::new(Cursor::new(bytes))
            .with_guessed_format()
            .unwrap()
            .into_decoder()
            .unwrap();
        assert_eq!(decoder.exif_metadata().unwrap(), None);
        assert_eq!(decoder.xmp_metadata().unwrap(), None);
        assert_eq!(decoder.iptc_metadata().unwrap(), None);
        assert_eq!(decoder.icc_profile().unwrap(), None);
        assert_eq!(decoder.orientation().unwrap(), Orientation::NoTransforms);
    }

    #[test]
    fn gps_exif_is_removed_and_orientation_is_baked_into_pixels() {
        let original = gps_jpeg();
        let mut decoder = ImageReader::with_format(Cursor::new(&original), ImageFormat::Jpeg)
            .into_decoder()
            .unwrap();
        assert!(decoder.exif_metadata().unwrap().is_some());
        assert_eq!(decoder.orientation().unwrap(), Orientation::Rotate90);
        let mut expected = DynamicImage::from_decoder(decoder).unwrap();
        expected.apply_orientation(Orientation::Rotate90);
        let temp = crate::test_support::TestTempDir::new("preview-gps-fixture");
        let path = temp.join("gps.jpg");
        std::fs::write(&path, &original).unwrap();
        let metadata = crate::metadata::extract_media_metadata(&path, &[], chrono::Utc::now());
        let geo = metadata.geo.expect("fixture must contain parseable GPS");
        assert!((geo.latitude - (12.0 + 34.0 / 60.0 + 56.0 / 3600.0)).abs() < 1e-6);
        let output = sanitize_hidden_photo(&original).unwrap();
        assert_no_metadata(&output);
        let decoded = image::load_from_memory(&output).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (20, 40));
        assert_eq!(decoded.to_rgb8(), expected.to_rgb8());
    }

    #[test]
    fn png_preserves_alpha_and_exact_samples_without_metadata() {
        let pixels = image::RgbaImage::from_fn(3, 2, |x, y| {
            image::Rgba([x as u8 * 57, y as u8 * 81, 124, x as u8 * 90])
        });
        let mut original = Vec::new();
        pixels
            .write_with_encoder(image::codecs::png::PngEncoder::new(&mut original))
            .unwrap();
        let output = sanitize_hidden_photo(&original).unwrap();
        assert_no_metadata(&output);
        assert_eq!(image::load_from_memory(&output).unwrap().to_rgba8(), pixels);
    }

    #[test]
    fn icc_is_normalized_and_never_copied() {
        let pixels = image::RgbImage::from_pixel(2, 2, image::Rgb([76, 140, 204]));
        let mut original = Vec::new();
        let mut encoder = image::codecs::png::PngEncoder::new(&mut original);
        encoder
            .set_icc_profile(ColorProfile::new_srgb().encode().unwrap())
            .unwrap();
        pixels.write_with_encoder(encoder).unwrap();
        let output = sanitize_hidden_photo(&original).unwrap();
        assert_no_metadata(&output);
        let decoded = image::load_from_memory(&output).unwrap().to_rgb8();
        for (actual, expected) in decoded.as_raw().iter().zip(pixels.as_raw()) {
            assert!(actual.abs_diff(*expected) <= 1);
        }
    }

    #[test]
    fn wide_gamut_icc_changes_colors_and_preserves_alpha() {
        let pixels = image::RgbaImage::from_pixel(2, 2, image::Rgba([76, 140, 204, 93]));
        let mut original = Vec::new();
        let mut encoder = image::codecs::png::PngEncoder::new(&mut original);
        encoder
            .set_icc_profile(ColorProfile::new_adobe_rgb().encode().unwrap())
            .unwrap();
        pixels.write_with_encoder(encoder).unwrap();
        let output = sanitize_hidden_photo(&original).unwrap();
        assert_no_metadata(&output);
        let decoded = image::load_from_memory(&output).unwrap().to_rgba8();
        assert_ne!(
            &decoded.get_pixel(0, 0).0[..3],
            &pixels.get_pixel(0, 0).0[..3]
        );
        assert!(decoded.pixels().all(|pixel| pixel.0[3] == 93));
    }

    #[test]
    fn sixteen_bit_png_samples_remain_exact() {
        let pixels = image::ImageBuffer::<image::Rgba<u16>, Vec<u16>>::from_pixel(
            2,
            2,
            image::Rgba([1, 10001, 60003, 32769]),
        );
        let mut original = Vec::new();
        pixels
            .write_with_encoder(image::codecs::png::PngEncoder::new(&mut original))
            .unwrap();
        let output = sanitize_hidden_photo(&original).unwrap();
        let decoded = image::load_from_memory(&output).unwrap();
        assert_eq!(decoded.color(), image::ColorType::Rgba16);
        assert_eq!(decoded.to_rgba16(), pixels);
    }

    fn png_chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut chunk = Vec::new();
        chunk.extend_from_slice(&(data.len() as u32).to_be_bytes());
        chunk.extend_from_slice(kind);
        chunk.extend_from_slice(data);
        let crc = png_crc(&chunk[4..]);
        chunk.extend_from_slice(&crc.to_be_bytes());
        chunk
    }

    fn add_png_chunk_at(png: &[u8], offset: usize, kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut output = png[..offset].to_vec();
        output.extend_from_slice(&png_chunk(kind, data));
        output.extend_from_slice(&png[offset..]);
        output
    }

    fn add_png_chunk(png: &[u8], kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
        add_png_chunk_at(png, 33, kind, data)
    }

    #[test]
    fn png_exif_orientation_is_applied_before_and_after_idat() {
        let pixels =
            image::RgbImage::from_fn(3, 2, |x, y| image::Rgb([x as u8 * 70, y as u8 * 90, 123]));
        let mut png = Vec::new();
        pixels
            .write_with_encoder(image::codecs::png::PngEncoder::new(&mut png))
            .unwrap();
        let mut jpeg = ImageReader::with_format(Cursor::new(gps_jpeg()), ImageFormat::Jpeg)
            .into_decoder()
            .unwrap();
        let exif = jpeg.exif_metadata().unwrap().unwrap();
        let mut expected = DynamicImage::ImageRgb8(pixels);
        expected.apply_orientation(Orientation::Rotate90);
        for offset in [33, png.len() - 12] {
            let original = add_png_chunk_at(&png, offset, b"eXIf", &exif);
            let output = sanitize_hidden_photo(&original).unwrap();
            assert_no_metadata(&output);
            assert_eq!(
                image::load_from_memory(&output).unwrap().to_rgb8(),
                expected.to_rgb8()
            );
        }
        let duplicate = add_png_chunk_at(
            &add_png_chunk(&png, b"eXIf", &exif),
            png.len() - 12 + exif.len() + 12,
            b"eXIf",
            &exif,
        );
        assert!(
            sanitize_hidden_photo(&duplicate)
                .unwrap_err()
                .contains("duplicate")
        );
        let mut bad_crc = add_png_chunk_at(&png, png.len() - 12, b"eXIf", &exif);
        let crc_offset = bad_crc.len() - 13;
        bad_crc[crc_offset] ^= 1;
        assert!(
            sanitize_hidden_photo(&bad_crc)
                .unwrap_err()
                .contains("checksum")
        );
    }

    #[test]
    fn sixteen_bit_icc_preserves_alpha_and_sample_precision() {
        let pixels = image::ImageBuffer::<image::Rgba<u16>, Vec<u16>>::from_pixel(
            2,
            2,
            image::Rgba([10001, 35003, 55007, 32769]),
        );
        let mut png = Vec::new();
        let mut encoder = image::codecs::png::PngEncoder::new(&mut png);
        encoder
            .set_icc_profile(ColorProfile::new_srgb().encode().unwrap())
            .unwrap();
        pixels.write_with_encoder(encoder).unwrap();
        let output = sanitize_hidden_photo(&png).unwrap();
        assert_no_metadata(&output);
        let decoded = image::load_from_memory(&output).unwrap();
        assert_eq!(decoded.color(), image::ColorType::Rgba16);
        for pixel in decoded.to_rgba16().pixels() {
            assert_eq!(pixel.0[3], 32769);
            for (actual, expected) in pixel.0[..3].iter().zip([10001u16, 35003, 55007]) {
                assert!(actual.abs_diff(expected) <= 16);
                assert_ne!(*actual % 257, 0, "samples must not be reduced to 8-bit");
            }
        }
    }

    #[test]
    fn png_dimensions_and_pixel_count_are_rejected_before_pixel_decode() {
        let pixels = image::RgbImage::new(1, 1);
        let mut png = Vec::new();
        pixels
            .write_with_encoder(image::codecs::png::PngEncoder::new(&mut png))
            .unwrap();
        for (width, height, expected) in [(16385u32, 1u32, "limit"), (8193, 8192, "pixel limit")] {
            let mut ihdr = png[16..29].to_vec();
            ihdr[..4].copy_from_slice(&width.to_be_bytes());
            ihdr[4..8].copy_from_slice(&height.to_be_bytes());
            let mut oversized = png[..8].to_vec();
            oversized.extend_from_slice(&png_chunk(b"IHDR", &ihdr));
            oversized.extend_from_slice(&png[33..]);
            assert!(
                sanitize_hidden_photo(&oversized)
                    .unwrap_err()
                    .to_lowercase()
                    .contains(expected)
            );
        }
    }

    #[test]
    fn png_color_tags_accept_srgb_and_reject_unsupported_colors() {
        let pixels = image::RgbImage::from_pixel(1, 1, image::Rgb([20, 100, 200]));
        let mut png = Vec::new();
        pixels
            .write_with_encoder(image::codecs::png::PngEncoder::new(&mut png))
            .unwrap();
        let nonstandard = add_png_chunk(&png, b"gAMA", &100000u32.to_be_bytes());
        assert!(
            image::load_from_memory(&nonstandard).is_ok(),
            "fixture is a valid decodable PNG"
        );
        assert!(
            sanitize_hidden_photo(&nonstandard)
                .unwrap_err()
                .contains("gamma")
        );
        let standard = add_png_chunk(&png, b"gAMA", &45455u32.to_be_bytes());
        assert!(sanitize_hidden_photo(&standard).is_ok());
        let explicit = add_png_chunk(&png, b"sRGB", &[0]);
        assert!(sanitize_hidden_photo(&explicit).is_ok());
        let chroma: Vec<u8> = [31270u32, 32900, 64000, 33000, 30000, 60000, 15000, 6000]
            .into_iter()
            .flat_map(u32::to_be_bytes)
            .collect();
        assert!(sanitize_hidden_photo(&add_png_chunk(&standard, b"cHRM", &chroma)).is_ok());
        let mut nonstandard_chroma = chroma;
        nonstandard_chroma[3] ^= 1;
        assert!(sanitize_hidden_photo(&add_png_chunk(&png, b"cHRM", &nonstandard_chroma)).is_err());
        assert!(sanitize_hidden_photo(&add_png_chunk(&png, b"cICP", &[9, 16, 0, 1])).is_err());
        assert!(sanitize_hidden_photo(&add_png_chunk(&png, b"cICP", &[1, 13, 0, 1])).is_ok());
        let mut truncated = png.clone();
        truncated[33..37].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(sanitize_hidden_photo(&truncated).is_err());
        assert!(sanitize_hidden_photo(&png[..png.len() - 1]).is_err());
    }

    #[test]
    fn jpeg_declared_but_incomplete_icc_is_rejected() {
        let original = gps_jpeg();
        // One APP2 fragment declares two fragments, but the second is absent.
        let mut payload = b"ICC_PROFILE\0".to_vec();
        payload.extend_from_slice(&[1, 2]);
        payload.extend_from_slice(&ColorProfile::new_srgb().encode().unwrap());
        let mut malformed = original[..2].to_vec();
        malformed.extend_from_slice(&[0xff, 0xe2]);
        malformed.extend_from_slice(&((payload.len() + 2) as u16).to_be_bytes());
        malformed.extend_from_slice(&payload);
        malformed.extend_from_slice(&original[2..]);
        let mut decoder = ImageReader::with_format(Cursor::new(&malformed), ImageFormat::Jpeg)
            .into_decoder()
            .unwrap();
        assert!(
            decoder.icc_profile().unwrap().is_none(),
            "fixture exercises dropped ICC"
        );
        assert!(
            DynamicImage::from_decoder(decoder).is_ok(),
            "fixture pixels still decode"
        );
        assert!(
            sanitize_hidden_photo(&malformed)
                .unwrap_err()
                .contains("ICC")
        );
        // A complete profile is accepted and normalized through the same path.
        let count_offset = 2 + 2 + 2 + 12 + 1;
        malformed[count_offset] = 1;
        let output = sanitize_hidden_photo(&malformed).unwrap();
        assert_no_metadata(&output);
        let pixels = image::load_from_memory(&output).unwrap();
        assert_eq!((pixels.width(), pixels.height()), (20, 40));
    }

    fn jpeg_with_icc_fragments(original: &[u8], fragments: &[Vec<u8>]) -> Vec<u8> {
        let mut jpeg = original[..2].to_vec();
        for payload in fragments {
            jpeg.extend_from_slice(&[0xff, 0xe2]);
            jpeg.extend_from_slice(&u16::try_from(payload.len() + 2).unwrap().to_be_bytes());
            jpeg.extend_from_slice(payload);
        }
        jpeg.extend_from_slice(&original[2..]);
        jpeg
    }

    fn icc_fragment(sequence: u8, count: u8, data: &[u8]) -> Vec<u8> {
        let mut payload = b"ICC_PROFILE\0".to_vec();
        payload.extend_from_slice(&[sequence, count]);
        payload.extend_from_slice(data);
        payload
    }

    #[test]
    fn jpeg_multipart_icc_is_complete_unique_and_bounded() {
        let original = gps_jpeg();
        let profile = ColorProfile::new_srgb().encode().unwrap();
        let (first, second) = profile.split_at(profile.len() / 2);
        // Segment order need not match sequence order.
        let valid = jpeg_with_icc_fragments(
            &original,
            &[icc_fragment(2, 2, second), icc_fragment(1, 2, first)],
        );
        assert_no_metadata(&sanitize_hidden_photo(&valid).unwrap());
        for fragments in [
            vec![icc_fragment(1, 2, first)],
            vec![icc_fragment(1, 2, first), icc_fragment(1, 2, second)],
            vec![icc_fragment(1, 2, first), icc_fragment(2, 3, second)],
            vec![icc_fragment(0, 1, first)],
            vec![icc_fragment(1, 0, first)],
            vec![icc_fragment(2, 1, first)],
            vec![b"ICC_PROFILE\0".to_vec()],
        ] {
            let jpeg = jpeg_with_icc_fragments(&original, &fragments);
            assert!(sanitize_hidden_photo(&jpeg).unwrap_err().contains("ICC"));
        }
        let fragment = vec![0u8; 65519];
        let fragments: Vec<_> = (1..=65)
            .map(|index| icc_fragment(index, 65, &fragment))
            .collect();
        let oversized = jpeg_with_icc_fragments(&original, &fragments);
        assert!(
            sanitize_hidden_photo(&oversized)
                .unwrap_err()
                .contains("profile limit")
        );
    }

    #[test]
    fn invalid_and_unsupported_images_fail_closed() {
        assert!(sanitize_hidden_photo(b"not an image").is_err());
        assert!(sanitize_hidden_photo(b"GIF89a").is_err());
        assert!(sanitize_hidden_photo(&[0xff, 0xd8, 0xff, 0xe0]).is_err());
        let pixels = image::RgbImage::new(1, 1);
        let mut bytes = Vec::new();
        let mut encoder = image::codecs::png::PngEncoder::new(&mut bytes);
        encoder.set_icc_profile(b"invalid ICC".to_vec()).unwrap();
        pixels.write_with_encoder(encoder).unwrap();
        assert!(sanitize_hidden_photo(&bytes).is_err());
    }
}
