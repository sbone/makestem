use serde::{Deserialize, Serialize};
use std::{ffi::OsStr, path::Path, process::Command};

#[derive(Debug, Serialize)]
pub struct AudioInspection {
    pub path: String,
    pub artist: Option<String>,
    pub title: String,
    pub format: String,
    pub codec: String,
    pub duration_seconds: f64,
    pub sample_rate: Option<u32>,
    pub channels: Option<u32>,
    pub bit_depth: Option<u32>,
    pub lossless: bool,
    pub source_bitrate_kbps: Option<u32>,
    pub source_vbr: Option<bool>,
    pub output_quality: String,
    pub readiness: Readiness,
    pub message: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Readiness {
    Ready,
    Warning,
    Blocked,
}

#[derive(Deserialize)]
struct ProbeOutput {
    #[serde(default)]
    streams: Vec<ProbeStream>,
    format: Option<ProbeFormat>,
    #[serde(default)]
    packets: Vec<ProbePacket>,
}

#[derive(Deserialize)]
struct ProbeStream {
    index: Option<u32>,
    codec_name: Option<String>,
    codec_type: Option<String>,
    sample_rate: Option<String>,
    channels: Option<u32>,
    bits_per_raw_sample: Option<String>,
    bits_per_sample: Option<u32>,
    bit_rate: Option<String>,
}

#[derive(Deserialize)]
struct ProbeFormat {
    format_name: Option<String>,
    duration: Option<String>,
    tags: Option<ProbeTags>,
    bit_rate: Option<String>,
}

#[derive(Deserialize)]
struct ProbePacket {
    stream_index: Option<u32>,
    size: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Mp3Encoding {
    Cbr(u32),
    Vbr { quality: u8, approximate_kbps: u32 },
}

impl Mp3Encoding {
    pub fn label(&self) -> String {
        match self {
            Self::Cbr(kbps) => format!("{kbps} kbps MP3"),
            Self::Vbr {
                quality,
                approximate_kbps,
            } => {
                format!("VBR quality {quality} MP3 (~{approximate_kbps} kbps)")
            }
        }
    }

    pub fn ffmpeg_args(&self) -> [&'static str; 2] {
        match self {
            Self::Cbr(_) => ["-b:a", ""],
            Self::Vbr { .. } => ["-q:a", ""],
        }
    }

    pub fn ffmpeg_value(&self) -> String {
        match self {
            Self::Cbr(kbps) => format!("{kbps}k"),
            Self::Vbr { quality, .. } => quality.to_string(),
        }
    }
}

#[derive(Deserialize)]
struct ProbeTags {
    #[serde(alias = "ARTIST")]
    artist: Option<String>,
    #[serde(alias = "TITLE")]
    title: Option<String>,
}

pub fn inspect_audio(path: &Path) -> Result<AudioInspection, String> {
    if !path.is_file() {
        return Err(format!("‘{}’ is not a readable file.", path.display()));
    }
    let output = Command::new("ffprobe")
        .args([
            OsStr::new("-v"),
            OsStr::new("error"),
            OsStr::new("-show_streams"),
            OsStr::new("-show_format"),
            OsStr::new("-show_packets"),
            OsStr::new("-read_intervals"),
            OsStr::new("%+5"),
            OsStr::new("-of"),
            OsStr::new("json"),
            path.as_os_str(),
        ])
        .output()
        .map_err(|error| format!("Could not run FFprobe: {error}"))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(if detail.is_empty() {
            "FFprobe could not read this file.".to_owned()
        } else {
            detail
        });
    }
    let probe: ProbeOutput = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("Could not understand FFprobe’s response: {error}"))?;
    let stream = probe
        .streams
        .iter()
        .find(|stream| stream.codec_type.as_deref() == Some("audio"))
        .ok_or_else(|| "No audio stream was found in this file.".to_owned())?;
    let format = probe.format;
    let codec = stream
        .codec_name
        .clone()
        .unwrap_or_else(|| "unknown".to_owned());
    let lossless =
        codec == "flac" || codec == "alac" || codec == "wavpack" || codec.starts_with("pcm_");
    let extension = path
        .extension()
        .and_then(OsStr::to_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let supported_container = matches!(
        extension.as_str(),
        "flac" | "wav" | "wave" | "aif" | "aiff" | "aifc" | "mp3" | "ogg" | "m4a" | "aac"
    );
    let (readiness, message) = if !supported_container {
        (
            Readiness::Blocked,
            "This file type is not currently supported. Choose FLAC, WAV, AIFF, MP3, OGG, M4A, or AAC."
                .to_owned(),
        )
    } else if stream.channels.unwrap_or(2) > 2 {
        (
            Readiness::Blocked,
            "Multichannel audio is not currently supported. Use a mono or stereo export."
                .to_owned(),
        )
    } else if lossless {
        (
            Readiness::Ready,
            "Lossless source—ready to create stems.".to_owned(),
        )
    } else {
        (
            Readiness::Warning,
            "Compressed source. MakeStem can process it, but a lossless source may produce cleaner stems."
                .to_owned(),
        )
    };
    let title = clean_text(
        &format
            .as_ref()
            .and_then(|format| format.tags.as_ref())
            .and_then(|tags| tags.title.clone())
            .filter(|title| !title.trim().is_empty())
            .or_else(|| path.file_stem().and_then(OsStr::to_str).map(str::to_owned))
            .unwrap_or_else(|| "Untitled".to_owned()),
    );
    let artist = format
        .as_ref()
        .and_then(|format| format.tags.as_ref())
        .and_then(|tags| tags.artist.as_deref())
        .and_then(clean_optional_text);
    let bit_depth = stream
        .bits_per_raw_sample
        .as_deref()
        .and_then(|value| value.parse().ok())
        .or(stream.bits_per_sample)
        .filter(|depth| *depth > 0);
    let source_bitrate_kbps = stream
        .bit_rate
        .as_deref()
        .or_else(|| format.as_ref().and_then(|value| value.bit_rate.as_deref()))
        .and_then(parse_bitrate_kbps);
    let source_vbr = (codec == "mp3").then(|| packet_sizes_vary(&probe.packets, stream.index));
    let output_encoding = choose_output_encoding(lossless, &codec, source_bitrate_kbps, source_vbr);

    Ok(AudioInspection {
        path: path.to_string_lossy().into_owned(),
        artist,
        title,
        format: friendly_format(
            format
                .as_ref()
                .and_then(|format| format.format_name.as_deref()),
            &codec,
        ),
        codec,
        duration_seconds: format
            .as_ref()
            .and_then(|format| format.duration.as_deref())
            .and_then(|duration| duration.parse().ok())
            .unwrap_or_default(),
        sample_rate: stream
            .sample_rate
            .as_deref()
            .and_then(|rate| rate.parse().ok()),
        channels: stream.channels,
        bit_depth,
        lossless,
        source_bitrate_kbps,
        source_vbr,
        output_quality: output_encoding.label(),
        readiness,
        message,
    })
}

fn clean_text(value: &str) -> String {
    clean_optional_text(value).unwrap_or_else(|| "Untitled".to_owned())
}

fn clean_optional_text(value: &str) -> Option<String> {
    let cleaned = value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    (!cleaned.is_empty()).then_some(cleaned)
}

pub fn encoding_for_audio(path: &Path) -> Result<Mp3Encoding, String> {
    let inspection = inspect_audio(path)?;
    Ok(choose_output_encoding(
        inspection.lossless,
        &inspection.codec,
        inspection.source_bitrate_kbps,
        inspection.source_vbr,
    ))
}

fn parse_bitrate_kbps(value: &str) -> Option<u32> {
    let bits: u64 = value.parse().ok()?;
    (bits > 0).then_some(((bits + 500) / 1_000) as u32)
}

fn packet_sizes_vary(packets: &[ProbePacket], stream_index: Option<u32>) -> bool {
    let mut sizes = packets
        .iter()
        .filter(|packet| stream_index.is_none() || packet.stream_index == stream_index)
        .filter_map(|packet| packet.size.as_deref()?.parse::<u32>().ok());
    let Some(first) = sizes.next() else {
        return false;
    };
    let (mut minimum, mut maximum, mut count) = (first, first, 1);
    for size in sizes {
        minimum = minimum.min(size);
        maximum = maximum.max(size);
        count += 1;
    }
    count >= 4 && maximum.saturating_sub(minimum) > 2
}

fn choose_output_encoding(
    lossless: bool,
    codec: &str,
    bitrate_kbps: Option<u32>,
    vbr: Option<bool>,
) -> Mp3Encoding {
    if lossless {
        return Mp3Encoding::Cbr(320);
    }
    if codec == "mp3" && vbr == Some(true) {
        let (quality, approximate_kbps) = match bitrate_kbps.unwrap_or(165) {
            0..=139 => (5, 130),
            140..=169 => (4, 165),
            170..=184 => (3, 175),
            185..=214 => (2, 190),
            215..=234 => (1, 225),
            _ => (0, 245),
        };
        return Mp3Encoding::Vbr {
            quality,
            approximate_kbps,
        };
    }
    const RATES: [u32; 14] = [
        32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
    ];
    let ceiling = bitrate_kbps.unwrap_or(192).clamp(32, 320);
    Mp3Encoding::Cbr(
        RATES
            .iter()
            .rev()
            .copied()
            .find(|rate| *rate <= ceiling)
            .unwrap_or(32),
    )
}

fn friendly_format(format: Option<&str>, codec: &str) -> String {
    if codec == "flac" {
        "FLAC".to_owned()
    } else if codec.starts_with("pcm_") {
        match format.unwrap_or_default() {
            value if value.contains("aiff") => "AIFF".to_owned(),
            _ => "WAV".to_owned(),
        }
    } else {
        codec.to_ascii_uppercase()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lossless_sources_use_full_quality_mp3() {
        assert_eq!(
            choose_output_encoding(true, "flac", None, None),
            Mp3Encoding::Cbr(320)
        );
    }

    #[test]
    fn cbr_sources_never_encode_above_the_reported_bitrate() {
        assert_eq!(
            choose_output_encoding(false, "mp3", Some(257), Some(false)),
            Mp3Encoding::Cbr(256)
        );
        assert_eq!(
            choose_output_encoding(false, "aac", Some(150), None),
            Mp3Encoding::Cbr(128)
        );
    }

    #[test]
    fn vbr_mp3_sources_keep_a_matching_vbr_profile() {
        assert_eq!(
            choose_output_encoding(false, "mp3", Some(198), Some(true)),
            Mp3Encoding::Vbr {
                quality: 2,
                approximate_kbps: 190,
            }
        );
    }

    #[test]
    fn missing_compressed_bitrate_uses_a_conservative_default() {
        assert_eq!(
            choose_output_encoding(false, "mp3", None, Some(false)),
            Mp3Encoding::Cbr(192)
        );
    }

    #[test]
    fn packet_size_variation_distinguishes_vbr_from_padding() {
        let packets = |sizes: &[u32]| {
            sizes
                .iter()
                .map(|size| ProbePacket {
                    stream_index: Some(0),
                    size: Some(size.to_string()),
                })
                .collect::<Vec<_>>()
        };
        assert!(!packet_sizes_vary(
            &packets(&[1044, 1045, 1044, 1045]),
            Some(0)
        ));
        assert!(packet_sizes_vary(&packets(&[520, 730, 1044, 835]), Some(0)));
    }
}
