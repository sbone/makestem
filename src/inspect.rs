use serde::{Deserialize, Serialize};
use std::{ffi::OsStr, path::Path, process::Command};

#[derive(Debug, Serialize)]
pub struct AudioInspection {
    pub path: String,
    pub title: String,
    pub format: String,
    pub codec: String,
    pub duration_seconds: f64,
    pub sample_rate: Option<u32>,
    pub channels: Option<u32>,
    pub bit_depth: Option<u32>,
    pub lossless: bool,
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
}

#[derive(Deserialize)]
struct ProbeStream {
    codec_name: Option<String>,
    codec_type: Option<String>,
    sample_rate: Option<String>,
    channels: Option<u32>,
    bits_per_raw_sample: Option<String>,
    bits_per_sample: Option<u32>,
}

#[derive(Deserialize)]
struct ProbeFormat {
    format_name: Option<String>,
    duration: Option<String>,
    tags: Option<ProbeTags>,
}

#[derive(Deserialize)]
struct ProbeTags {
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
            "Compressed source. Stemcraft can process it, but a lossless source may produce cleaner stems."
                .to_owned(),
        )
    };
    let title = format
        .as_ref()
        .and_then(|format| format.tags.as_ref())
        .and_then(|tags| tags.title.clone())
        .filter(|title| !title.trim().is_empty())
        .or_else(|| path.file_stem().and_then(OsStr::to_str).map(str::to_owned))
        .unwrap_or_else(|| "Untitled".to_owned());
    let bit_depth = stream
        .bits_per_raw_sample
        .as_deref()
        .and_then(|value| value.parse().ok())
        .or(stream.bits_per_sample)
        .filter(|depth| *depth > 0);

    Ok(AudioInspection {
        path: path.to_string_lossy().into_owned(),
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
        readiness,
        message,
    })
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
