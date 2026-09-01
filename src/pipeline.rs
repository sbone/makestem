use sha2::{Digest, Sha256};
use std::{
    ffi::OsStr,
    fs, io,
    io::{BufReader, Read},
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    thread,
};

const MODEL: &str = "htdemucs_ft";
const BITRATE: &str = "320k";
const MODEL_FILENAME: &str = "htdemucs_ft.safetensors";
const MODEL_SIZE: u64 = 336_125_008;
const MODEL_SHA256: &str = "255c2650d26537ce4887c9c4cf08c6d4896fad2fecc0b78dc5b875b117bcc575";
const MODEL_DOWNLOAD_SPACE: u64 = 500 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Product {
    Acapella,
    Instrumental,
}

impl Product {
    fn label(self) -> &'static str {
        match self {
            Self::Acapella => "Acapella",
            Self::Instrumental => "Instrumental",
        }
    }

    fn suffix(self) -> String {
        self.label().to_owned()
    }
}

#[derive(Debug)]
pub struct PipelineError {
    pub message: String,
    pub guidance: Option<String>,
}

impl PipelineError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            guidance: None,
        }
    }

    fn guided(message: impl Into<String>, guidance: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            guidance: Some(guidance.into()),
        }
    }
}

pub type Result<T> = std::result::Result<T, PipelineError>;

#[derive(Clone, Debug)]
pub enum Event {
    StageStarted(String),
    StageProgress {
        detail: String,
        percent: Option<u64>,
    },
    StageCompleted(String),
}

pub trait Reporter {
    fn report(&mut self, event: Event);
}

pub struct Pipeline {
    input: PathBuf,
    output_dir: PathBuf,
    work_dir: PathBuf,
    title: String,
}

struct PendingOutput {
    destination: PathBuf,
    temporary: PathBuf,
    backup: PathBuf,
}

impl Pipeline {
    pub fn new(input: impl AsRef<Path>) -> Result<Self> {
        let input = input.as_ref();
        if !input.exists() {
            return Err(PipelineError::guided(
                format!("Could not find ‘{}’.", display_path(input)),
                "Check the filename, or drag the audio file into the terminal after the command.",
            ));
        }
        if !input.is_file() {
            return Err(PipelineError::new(format!(
                "‘{}’ is not a file.",
                display_path(input)
            )));
        }
        let input = fs::canonicalize(input).map_err(|e| PipelineError::new(e.to_string()))?;
        validate_audio(&input)?;
        let parent = input.parent().unwrap_or_else(|| Path::new("."));
        let output_dir = parent.join("output");
        let work_dir = parent.join(format!(".makestem-work-{}", std::process::id()));
        let title = clean_tag(&read_title(&input).unwrap_or_else(|| {
            input
                .file_stem()
                .and_then(OsStr::to_str)
                .unwrap_or("Untitled")
                .to_owned()
        }));
        Ok(Self {
            input,
            output_dir,
            work_dir,
            title,
        })
    }

    pub fn preflight() -> Result<()> {
        require_tool(
            "demucs",
            "Install the native Demucs CLI and ensure `demucs` is on your PATH.",
        )?;
        require_tool(
            "ffmpeg",
            "Install FFmpeg (on macOS: `brew install ffmpeg`).",
        )?;
        require_tool(
            "ffprobe",
            "FFprobe normally ships with FFmpeg (on macOS: `brew install ffmpeg`).",
        )?;
        Ok(())
    }

    pub fn run(
        mut self,
        products: &[Product],
        replace: bool,
        reporter: &mut impl Reporter,
    ) -> Result<Vec<PathBuf>> {
        fs::create_dir_all(&self.output_dir).map_err(|e| {
            PipelineError::guided(
                format!("Could not create ‘{}’: {e}", display_path(&self.output_dir)),
                "Check that you have permission to write beside the source track.",
            )
        })?;
        let existing: Vec<PathBuf> = products
            .iter()
            .map(|product| self.output_path(*product))
            .filter(|path| path.exists())
            .collect();
        if !replace && !existing.is_empty() {
            let names = existing
                .iter()
                .filter_map(|path| path.file_name())
                .map(|name| format!("‘{}’", clean_terminal_text(&name.to_string_lossy())))
                .collect::<Vec<_>>()
                .join(", ");
            return Err(PipelineError::guided(
                format!("Output already exists: {names}."),
                "Choose Replace Existing Files in the app, or run the CLI again with `--replace`.",
            ));
        }
        if self.work_dir.exists() {
            fs::remove_dir_all(&self.work_dir).map_err(|e| PipelineError::new(e.to_string()))?;
        }
        fs::create_dir_all(&self.work_dir).map_err(|e| PipelineError::new(e.to_string()))?;

        let result = self.run_inner(products, replace, reporter);
        let _ = fs::remove_dir_all(&self.work_dir);
        result
    }

    fn run_inner(
        &mut self,
        products: &[Product],
        replace: bool,
        reporter: &mut impl Reporter,
    ) -> Result<Vec<PathBuf>> {
        prepare_model(reporter)?;
        let only_acapella = products == [Product::Acapella];
        let mut args = vec![self.input.as_os_str().to_owned(), "-m".into(), MODEL.into()];
        if only_acapella {
            args.extend(["-s".into(), "vocals".into()]);
        }
        args.extend(["-o".into(), self.work_dir.as_os_str().to_owned()]);
        run_demucs(&args, reporter)?;

        let pending: Vec<PendingOutput> = products
            .iter()
            .enumerate()
            .map(|(index, product)| self.pending_output(*product, index))
            .collect();
        for (product, output) in products.iter().zip(&pending) {
            let result = match product {
                Product::Acapella => self.encode_acapella(&output.temporary, reporter),
                Product::Instrumental => self.encode_instrumental(&output.temporary, reporter),
            };
            if let Err(error) = result {
                cleanup_pending(&pending);
                return Err(error);
            }
        }
        commit_outputs(&pending, replace)?;
        Ok(pending
            .into_iter()
            .map(|output| output.destination)
            .collect())
    }

    fn encode_acapella(&self, destination: &Path, reporter: &mut impl Reporter) -> Result<()> {
        let vocals = find_file(&self.work_dir, "vocals.wav")?;
        let title = format!("{} ({})", self.title, Product::Acapella.suffix());
        let args = ffmpeg_metadata_args(&vocals, &self.input, destination, &title);
        run_stage("Encoding 320 kbps acapella", "ffmpeg", &args, reporter)
    }

    fn encode_instrumental(&self, destination: &Path, reporter: &mut impl Reporter) -> Result<()> {
        let drums = find_file(&self.work_dir, "drums.wav")?;
        let bass = find_file(&self.work_dir, "bass.wav")?;
        let other = find_file(&self.work_dir, "other.wav")?;
        let title = format!("{} ({})", self.title, Product::Instrumental.suffix());
        let args = vec![
            "-hide_banner".into(),
            "-loglevel".into(),
            "error".into(),
            "-y".into(),
            "-i".into(),
            drums.into_os_string(),
            "-i".into(),
            bass.into_os_string(),
            "-i".into(),
            other.into_os_string(),
            "-i".into(),
            self.input.as_os_str().to_owned(),
            "-filter_complex".into(),
            "amix=inputs=3:duration=longest:normalize=0".into(),
            "-map_metadata".into(),
            "3".into(),
            "-metadata".into(),
            format!("title={title}").into(),
            "-c:a".into(),
            "libmp3lame".into(),
            "-b:a".into(),
            BITRATE.into(),
            destination.as_os_str().to_owned(),
        ];
        run_stage(
            "Mixing and encoding 320 kbps instrumental",
            "ffmpeg",
            &args,
            reporter,
        )
    }

    fn output_path(&self, product: Product) -> PathBuf {
        let base = self
            .input
            .file_stem()
            .and_then(OsStr::to_str)
            .unwrap_or("track");
        self.output_dir
            .join(format!("{base} ({}).mp3", product.suffix()))
    }

    fn pending_output(&self, product: Product, index: usize) -> PendingOutput {
        let process = std::process::id();
        PendingOutput {
            destination: self.output_path(product),
            temporary: self
                .output_dir
                .join(format!(".makestem-output-{process}-{index}.mp3")),
            backup: self
                .output_dir
                .join(format!(".makestem-backup-{process}-{index}.mp3")),
        }
    }
}

fn cleanup_pending(outputs: &[PendingOutput]) {
    for output in outputs {
        let _ = fs::remove_file(&output.temporary);
    }
}

fn commit_outputs(outputs: &[PendingOutput], replace: bool) -> Result<()> {
    let mut backed_up = Vec::new();
    let mut committed = Vec::new();

    if replace {
        for (index, output) in outputs.iter().enumerate() {
            let _ = fs::remove_file(&output.backup);
            if output.destination.exists() {
                if let Err(error) = fs::rename(&output.destination, &output.backup) {
                    restore_outputs(outputs, &backed_up, &committed);
                    cleanup_pending(outputs);
                    return Err(PipelineError::guided(
                        format!("Could not safely replace an existing output: {error}"),
                        "The existing files were preserved. Check output-folder permissions and try again.",
                    ));
                }
                backed_up.push(index);
            }
        }
    }

    for (index, output) in outputs.iter().enumerate() {
        let result = if replace {
            fs::rename(&output.temporary, &output.destination)
        } else {
            fs::hard_link(&output.temporary, &output.destination)
        };
        if let Err(error) = result {
            restore_outputs(outputs, &backed_up, &committed);
            cleanup_pending(outputs);
            return Err(PipelineError::guided(
                format!("Could not save the finished output: {error}"),
                if output.destination.exists() {
                    "An output appeared while MakeStem was working. It was preserved; confirm replacement and try again."
                } else {
                    "Existing files were preserved. Check output-folder permissions and try again."
                },
            ));
        }
        committed.push(index);
        if !replace {
            let _ = fs::remove_file(&output.temporary);
        }
    }

    for index in backed_up {
        let _ = fs::remove_file(&outputs[index].backup);
    }
    Ok(())
}

fn restore_outputs(outputs: &[PendingOutput], backed_up: &[usize], committed: &[usize]) {
    for index in committed.iter().rev() {
        let _ = fs::remove_file(&outputs[*index].destination);
    }
    for index in backed_up.iter().rev() {
        let _ = fs::rename(&outputs[*index].backup, &outputs[*index].destination);
    }
}

pub fn model_path() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join("Library/Caches/demucs-rs").join(MODEL_FILENAME))
    }
    #[cfg(not(target_os = "macos"))]
    {
        std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
            .map(|cache| cache.join("demucs-rs").join(MODEL_FILENAME))
    }
}

pub fn prepare_model(reporter: &mut impl Reporter) -> Result<PathBuf> {
    let path = model_path().ok_or_else(|| {
        PipelineError::guided(
            "Could not determine where to store the audio-separation model.",
            "Check that your HOME directory is configured and writable.",
        )
    })?;
    if path.is_file() && validate_model(&path).is_ok() {
        reporter.report(Event::StageCompleted(
            "Audio-separation model ready".to_owned(),
        ));
        return Ok(path);
    }

    if path.exists() {
        reporter.report(Event::StageStarted(
            "Replacing an incomplete audio-separation model".to_owned(),
        ));
        fs::remove_file(&path).map_err(|e| {
            PipelineError::guided(
                format!("Could not replace the incomplete model: {e}"),
                "Remove the model from Library/Caches/demucs-rs, then try again.",
            )
        })?;
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| PipelineError::new(e.to_string()))?;
        ensure_download_space(parent)?;
    }

    require_tool(
        "demucs",
        "Install the native Demucs CLI and ensure `demucs` is on your PATH.",
    )?;
    let missing_input = std::env::temp_dir().join(format!(
        ".makestem-model-download-{}-input.wav",
        std::process::id()
    ));
    let unused_output = std::env::temp_dir().join(format!(
        ".makestem-model-download-{}-output",
        std::process::id()
    ));
    let args = vec![
        missing_input.into_os_string(),
        "-m".into(),
        MODEL.into(),
        "-s".into(),
        "vocals".into(),
        "-o".into(),
        unused_output.into_os_string(),
    ];
    let result = run_demucs_with_label(&args, "Downloading audio-separation model", reporter);
    if path.is_file() {
        if let Err(error) = validate_model(&path) {
            let _ = fs::remove_file(&path);
            return Err(error);
        }
        reporter.report(Event::StageCompleted(
            "Audio-separation model ready".to_owned(),
        ));
        Ok(path)
    } else {
        result.map(|_| path)
    }
}

fn validate_model(path: &Path) -> Result<()> {
    let metadata = fs::metadata(path).map_err(|e| PipelineError::new(e.to_string()))?;
    if metadata.len() != MODEL_SIZE {
        return Err(PipelineError::guided(
            "The audio-separation model download is incomplete.",
            "Try the model download again. MakeStem will replace the partial file.",
        ));
    }
    let file = fs::File::open(path).map_err(|e| PipelineError::new(e.to_string()))?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    io::copy(&mut reader, &mut hasher).map_err(|e| PipelineError::new(e.to_string()))?;
    let digest = format!("{:x}", hasher.finalize());
    if digest != MODEL_SHA256 {
        return Err(PipelineError::guided(
            "The audio-separation model failed its integrity check.",
            "Try the model download again. MakeStem will replace the damaged file.",
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn ensure_download_space(path: &Path) -> Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let path = std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| {
        PipelineError::new("The model cache path contains an unsupported character.")
    })?;
    let mut stats = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    let result = unsafe { libc::statvfs(path.as_ptr(), stats.as_mut_ptr()) };
    if result == 0 {
        let stats = unsafe { stats.assume_init() };
        let available = u64::from(stats.f_bavail) * stats.f_frsize;
        if available < MODEL_DOWNLOAD_SPACE {
            return Err(PipelineError::guided(
                "There is not enough free space to download the audio-separation model.",
                "Free at least 500 MB on this Mac, then try again.",
            ));
        }
    }
    Ok(())
}

#[cfg(not(unix))]
fn ensure_download_space(_path: &Path) -> Result<()> {
    Ok(())
}

fn require_tool(tool: &str, guidance: &str) -> Result<()> {
    Command::new(tool).arg("--help").output().map_err(|e| {
        if e.kind() == io::ErrorKind::NotFound {
            PipelineError::guided(format!("Required tool `{tool}` was not found."), guidance)
        } else {
            PipelineError::new(format!("Could not run `{tool}`: {e}"))
        }
    })?;
    Ok(())
}

fn run_stage(
    label: &str,
    program: &str,
    args: &[std::ffi::OsString],
    reporter: &mut impl Reporter,
) -> Result<()> {
    reporter.report(Event::StageStarted(label.to_owned()));
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|e| PipelineError::new(format!("Could not start `{program}`: {e}")))?;
    if output.status.success() {
        reporter.report(Event::StageCompleted(label.to_owned()));
        Ok(())
    } else {
        Err(command_error(label, program, output))
    }
}

fn run_demucs(args: &[std::ffi::OsString], reporter: &mut impl Reporter) -> Result<()> {
    run_demucs_with_label(args, "Separating audio with Demucs", reporter)
}

fn run_demucs_with_label(
    args: &[std::ffi::OsString],
    label: &str,
    reporter: &mut impl Reporter,
) -> Result<()> {
    reporter.report(Event::StageStarted(label.to_owned()));
    #[cfg(target_os = "macos")]
    let mut child = Command::new("/usr/bin/script")
        .args(["-qF", "/dev/null", "demucs"])
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| PipelineError::new(format!("Could not start Demucs terminal: {e}")))?;
    #[cfg(not(target_os = "macos"))]
    let mut child = Command::new("demucs")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| PipelineError::new(format!("Could not start `demucs`: {e}")))?;

    #[cfg(target_os = "macos")]
    let progress_output = child.stdout.take().expect("piped stdout");
    #[cfg(target_os = "macos")]
    let secondary_output = child.stderr.take().expect("piped stderr");
    #[cfg(not(target_os = "macos"))]
    let progress_output = child.stderr.take().expect("piped stderr");
    #[cfg(not(target_os = "macos"))]
    let secondary_output = child.stdout.take().expect("piped stdout");

    let secondary_reader = thread::spawn(move || {
        let mut secondary_output = secondary_output;
        let mut captured = Vec::new();
        let _ = secondary_output.read_to_end(&mut captured);
        captured
    });
    let mut reader = BufReader::new(progress_output);
    let mut captured_progress = Vec::new();
    let mut chunk = Vec::new();
    let mut byte = [0_u8; 1];

    loop {
        let read = reader
            .read(&mut byte)
            .map_err(|e| PipelineError::new(format!("Could not read Demucs progress: {e}")))?;
        if read == 0 {
            report_demucs_chunk(&chunk, reporter);
            break;
        }
        captured_progress.push(byte[0]);
        if byte[0] == b'\r' || byte[0] == b'\n' {
            report_demucs_chunk(&chunk, reporter);
            chunk.clear();
        } else {
            chunk.push(byte[0]);
        }
    }

    let status = child
        .wait()
        .map_err(|e| PipelineError::new(format!("Could not wait for Demucs: {e}")))?;
    let secondary = secondary_reader.join().unwrap_or_default();
    if status.success() {
        reporter.report(Event::StageCompleted(label.to_owned()));
        Ok(())
    } else {
        Err(command_error(
            label,
            "demucs",
            Output {
                status,
                stdout: Vec::new(),
                stderr: [captured_progress, secondary].concat(),
            },
        ))
    }
}

fn report_demucs_chunk(chunk: &[u8], reporter: &mut impl Reporter) {
    let line = String::from_utf8_lossy(chunk);
    if let Some((detail, percent)) = demucs_progress(&line) {
        reporter.report(Event::StageProgress { detail, percent });
    }
}

fn demucs_progress(line: &str) -> Option<(String, Option<u64>)> {
    let cleaned = clean_terminal_text(&strip_ansi(line));
    if cleaned.is_empty() {
        return None;
    }
    let lower = cleaned.to_ascii_lowercase();
    let steps = extract_fraction(&cleaned);
    let download_bytes = extract_byte_ratio(&cleaned);
    let percent = extract_percent(&cleaned)
        .or_else(|| {
            download_bytes.and_then(|(current, total)| {
                (total > 0.0).then_some(((current * 100.0 / total) as u64).min(100))
            })
        })
        .or_else(|| {
            steps.and_then(|(current, total)| {
                (total > 0).then_some((current.saturating_mul(100) / total).min(100))
            })
        });
    let detail = if lower.contains("download") || download_bytes.is_some() {
        download_bytes.map_or_else(
            || "Downloading audio-separation model (first use)".to_owned(),
            |(current, total)| {
                format!(
                    "Downloading audio-separation model • {:.0} of {:.0} MB",
                    current / 1_000_000.0,
                    total / 1_000_000.0
                )
            },
        )
    } else if lower.contains("loading cached model") {
        "Loading cached audio-separation model".to_owned()
    } else if lower.starts_with("reading ") || lower.contains(" samples,") {
        "Reading source audio".to_owned()
    } else if lower.contains("loading model") {
        "Preparing audio-separation model".to_owned()
    } else if lower.contains("pre-compiling gpu shaders") {
        "Preparing GPU (first use only)".to_owned()
    } else if lower.contains("separating") || percent.is_some() {
        match steps {
            Some((current, total)) => {
                let chunk = extract_fraction_after(&lower, "chunk ")
                    .map(|(current, total)| format!(" • chunk {current} of {total}"))
                    .unwrap_or_default();
                format!("Analyzing audio • step {current} of {total}{chunk}")
            }
            None => "Analyzing and separating audio".to_owned(),
        }
    } else if lower.contains("wrote ") {
        "Writing separated stems".to_owned()
    } else {
        return None;
    };
    Some((detail, percent))
}

fn extract_percent(value: &str) -> Option<u64> {
    let (before_percent, _) = value.split_once('%')?;
    let digits: String = before_percent
        .chars()
        .rev()
        .take_while(|character| character.is_ascii_digit() || character.is_whitespace())
        .filter(char::is_ascii_digit)
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    digits.parse::<u64>().ok().filter(|value| *value <= 100)
}

fn extract_fraction(value: &str) -> Option<(u64, u64)> {
    let bytes = value.as_bytes();
    for slash in bytes
        .iter()
        .enumerate()
        .filter_map(|(index, byte)| (*byte == b'/').then_some(index))
    {
        let left = bytes[..slash]
            .iter()
            .rposition(|byte| !byte.is_ascii_digit())
            .map_or(0, |index| index + 1);
        let right = bytes[slash + 1..]
            .iter()
            .position(|byte| !byte.is_ascii_digit())
            .map_or(bytes.len(), |index| slash + 1 + index);
        if left < slash && slash + 1 < right {
            let current = value[left..slash].parse().ok()?;
            let total = value[slash + 1..right].parse().ok()?;
            return Some((current, total));
        }
    }
    None
}

fn extract_fraction_after(value: &str, marker: &str) -> Option<(u64, u64)> {
    let start = value.find(marker)? + marker.len();
    extract_fraction(&value[start..])
}

fn extract_byte_ratio(value: &str) -> Option<(f64, f64)> {
    for slash in value.match_indices('/').map(|(index, _)| index) {
        let left = parse_measurement_from_end(&value[..slash]);
        let right = parse_measurement_from_start(&value[slash + 1..]);
        if let (Some(left), Some(right)) = (left, right) {
            return Some((left, right));
        }
    }
    None
}

fn parse_measurement_from_end(value: &str) -> Option<f64> {
    let value = value.trim_end();
    let unit_start = value.rfind(|character: char| !character.is_ascii_alphabetic())? + 1;
    let unit = &value[unit_start..];
    let number_end = value[..unit_start].trim_end().len();
    let number_start = value[..number_end]
        .rfind(|character: char| !character.is_ascii_digit() && character != '.')
        .map_or(0, |index| index + 1);
    parse_bytes(&value[number_start..number_end], unit)
}

fn parse_measurement_from_start(value: &str) -> Option<f64> {
    let value = value.trim_start();
    let number_end =
        value.find(|character: char| !character.is_ascii_digit() && character != '.')?;
    let rest = value[number_end..].trim_start();
    let unit_end = rest
        .find(|character: char| !character.is_ascii_alphabetic())
        .unwrap_or(rest.len());
    parse_bytes(&value[..number_end], &rest[..unit_end])
}

fn parse_bytes(number: &str, unit: &str) -> Option<f64> {
    let value: f64 = number.parse().ok()?;
    let multiplier = match unit.to_ascii_lowercase().as_str() {
        "b" => 1.0,
        "kb" => 1_000.0,
        "kib" => 1_024.0,
        "mb" => 1_000_000.0,
        "mib" => 1_048_576.0,
        "gb" => 1_000_000_000.0,
        "gib" => 1_073_741_824.0,
        _ => return None,
    };
    Some(value * multiplier)
}

fn strip_ansi(value: &str) -> String {
    let mut output = String::new();
    let mut characters = value.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '\u{1b}' && characters.peek() == Some(&'[') {
            characters.next();
            for sequence_character in characters.by_ref() {
                if sequence_character.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            output.push(character);
        }
    }
    output
}

fn command_error(label: &str, program: &str, output: Output) -> PipelineError {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let detail = useful_diagnostic(&stderr);
    let guidance = diagnostic_guidance(&stderr).unwrap_or_else(|| {
        format!(
            "Run `{program} --help` to confirm the installed version, then retry. Temporary files were cleaned up."
        )
    });
    PipelineError::guided(format!("{label} failed: {detail}"), guidance)
}

fn validate_audio(input: &Path) -> Result<()> {
    let output = Command::new("ffprobe")
        .args([
            OsStr::new("-v"),
            OsStr::new("error"),
            OsStr::new("-select_streams"),
            OsStr::new("a:0"),
            OsStr::new("-show_entries"),
            OsStr::new("stream=codec_name"),
            OsStr::new("-of"),
            OsStr::new("default=noprint_wrappers=1:nokey=1"),
            input.as_os_str(),
        ])
        .output()
        .map_err(|e| PipelineError::new(format!("Could not inspect the audio file: {e}")))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(PipelineError::guided(
            format!(
                "Could not read ‘{}’: {}",
                display_path(input),
                useful_diagnostic(&stderr)
            ),
            diagnostic_guidance(&stderr).unwrap_or_else(|| {
                "The file may be damaged, incomplete, or use a codec this FFmpeg build does not support."
                    .to_owned()
            }),
        ));
    }
    if output.stdout.iter().all(u8::is_ascii_whitespace) {
        return Err(PipelineError::guided(
            format!(
                "‘{}’ does not contain an audio stream.",
                display_path(input)
            ),
            "Choose an audio file rather than artwork, a playlist, or a video with no audio track.",
        ));
    }
    Ok(())
}

fn useful_diagnostic(stderr: &str) -> String {
    let lines: Vec<String> = stderr
        .split(['\r', '\n'])
        .map(clean_terminal_text)
        .filter(|line| !line.is_empty())
        .filter(|line| {
            let lower = line.to_ascii_lowercase();
            !lower.starts_with("ffmpeg version")
                && !lower.starts_with("configuration:")
                && !lower.starts_with("libav")
        })
        .collect();
    lines
        .iter()
        .rev()
        .take(2)
        .rev()
        .cloned()
        .collect::<Vec<_>>()
        .join(" — ")
        .chars()
        .take(500)
        .collect::<String>()
        .trim()
        .to_owned()
        .pipe_nonempty("No additional details were reported.")
}

fn diagnostic_guidance(stderr: &str) -> Option<String> {
    let text = stderr.to_ascii_lowercase();
    let message = if text.contains("no space left on device") {
        "The disk is full. Free some space on the source/output volume and retry."
    } else if text.contains("permission denied") || text.contains("operation not permitted") {
        "MakeStem cannot read the source or write the result. Check file and folder permissions."
    } else if text.contains("invalid data found")
        || text.contains("moov atom not found")
        || text.contains("end of file")
    {
        "The file appears damaged or incomplete. Confirm it plays fully, or re-export it before retrying."
    } else if text.contains("unknown encoder") || text.contains("encoder 'libmp3lame'") {
        "This FFmpeg build lacks MP3 encoding support. Install a full FFmpeg build with libmp3lame."
    } else if text.contains("unsupported") || text.contains("unknown format") {
        "The audio format or codec is not supported by the installed tool. Re-export it as FLAC or WAV."
    } else if text.contains("model") && (text.contains("download") || text.contains("not found")) {
        "The Demucs model is missing or could not be downloaded. Check the network and model installation."
    } else {
        return None;
    };
    Some(message.to_owned())
}

fn clean_tag(value: &str) -> String {
    let cleaned = clean_terminal_text(value);
    if cleaned.is_empty() {
        "Untitled".to_owned()
    } else {
        cleaned
    }
}

fn clean_terminal_text(value: &str) -> String {
    value
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
        .join(" ")
}

fn display_path(path: &Path) -> String {
    clean_terminal_text(&path.to_string_lossy())
}

trait NonemptyString {
    fn pipe_nonempty(self, fallback: &str) -> String;
}

impl NonemptyString for String {
    fn pipe_nonempty(self, fallback: &str) -> String {
        if self.is_empty() {
            fallback.to_owned()
        } else {
            self
        }
    }
}

fn ffmpeg_metadata_args(
    audio: &Path,
    source: &Path,
    destination: &Path,
    title: &str,
) -> Vec<std::ffi::OsString> {
    vec![
        "-hide_banner".into(),
        "-loglevel".into(),
        "error".into(),
        "-y".into(),
        "-i".into(),
        audio.as_os_str().to_owned(),
        "-i".into(),
        source.as_os_str().to_owned(),
        "-map".into(),
        "0:a:0".into(),
        "-map_metadata".into(),
        "1".into(),
        "-metadata".into(),
        format!("title={title}").into(),
        "-c:a".into(),
        "libmp3lame".into(),
        "-b:a".into(),
        BITRATE.into(),
        destination.as_os_str().to_owned(),
    ]
}

fn read_title(input: &Path) -> Option<String> {
    let output = Command::new("ffprobe")
        .args([
            OsStr::new("-v"),
            OsStr::new("error"),
            OsStr::new("-show_entries"),
            OsStr::new("format_tags=title"),
            OsStr::new("-of"),
            OsStr::new("default=noprint_wrappers=1:nokey=1"),
            input.as_os_str(),
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let title = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!title.is_empty()).then_some(title)
}

fn find_file(root: &Path, name: &str) -> Result<PathBuf> {
    fn visit(dir: &Path, name: &str) -> io::Result<Option<PathBuf>> {
        for entry in fs::read_dir(dir)? {
            let path = entry?.path();
            if path.is_dir() {
                if let Some(found) = visit(&path, name)? {
                    return Ok(Some(found));
                }
            } else if path.file_name() == Some(OsStr::new(name)) {
                return Ok(Some(path));
            }
        }
        Ok(None)
    }
    visit(root, name).map_err(|e| PipelineError::new(e.to_string()))?.ok_or_else(|| {
        PipelineError::guided(
            format!("Demucs finished, but `{name}` was not produced."),
            "Confirm that the installed Demucs supports the htdemucs_ft model and standard stem names.",
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_directory(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "makestem-pipeline-{label}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn pending(directory: &Path, index: usize) -> PendingOutput {
        PendingOutput {
            destination: directory.join(format!("output-{index}.mp3")),
            temporary: directory.join(format!("temporary-{index}.mp3")),
            backup: directory.join(format!("backup-{index}.mp3")),
        }
    }

    #[test]
    fn cleans_control_characters_from_tags_and_messages() {
        assert_eq!(clean_tag("A\nTitle\u{1b}[31m"), "A Title [31m");
        assert_eq!(clean_tag("\n\t"), "Untitled");
    }

    #[test]
    fn selects_concise_diagnostics() {
        let stderr =
            "ffmpeg version 8\nconfiguration: noisy\nFirst useful line\nLast useful line\n";
        assert_eq!(
            useful_diagnostic(stderr),
            "First useful line — Last useful line"
        );
        assert_eq!(
            demucs_progress("[####>---] 12.5 MiB/333.0 MiB (21s)"),
            Some((
                "Downloading audio-separation model • 13 of 349 MB".to_owned(),
                Some(3)
            ))
        );
    }

    #[test]
    fn gives_guidance_for_common_external_failures() {
        assert!(
            diagnostic_guidance("No space left on device")
                .unwrap()
                .contains("disk is full")
        );
        assert!(
            diagnostic_guidance("Invalid data found")
                .unwrap()
                .contains("damaged")
        );
        assert!(diagnostic_guidance("unclassified failure").is_none());
    }

    #[test]
    fn recognizes_demucs_phases_and_percentages() {
        assert_eq!(
            demucs_progress("Loading cached model: htdemucs_ft"),
            Some(("Loading cached audio-separation model".to_owned(), None))
        );
        assert_eq!(
            demucs_progress("\u{1b}[2KSeparating  42%"),
            Some(("Analyzing and separating audio".to_owned(), Some(42)))
        );
        assert_eq!(demucs_progress("unrelated diagnostic"), None);
        assert_eq!(
            demucs_progress("Separating [####>---] 23/72 (1m 12s) chunk 1/2"),
            Some((
                "Analyzing audio • step 23 of 72 • chunk 1 of 2".to_owned(),
                Some(31)
            ))
        );
    }

    #[test]
    fn refuses_to_replace_an_output_without_permission() {
        let directory = test_directory("preserve");
        let output = pending(&directory, 0);
        fs::write(&output.destination, b"original").unwrap();
        fs::write(&output.temporary, b"new").unwrap();

        let error = commit_outputs(&[output], false).unwrap_err();

        assert!(error.message.contains("Could not save"));
        assert_eq!(
            fs::read(directory.join("output-0.mp3")).unwrap(),
            b"original"
        );
        assert!(!directory.join("temporary-0.mp3").exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn replaces_outputs_only_after_all_encodes_are_ready() {
        let directory = test_directory("replace");
        let outputs = [pending(&directory, 0), pending(&directory, 1)];
        for (index, output) in outputs.iter().enumerate() {
            fs::write(&output.destination, format!("old-{index}")).unwrap();
            fs::write(&output.temporary, format!("new-{index}")).unwrap();
        }

        commit_outputs(&outputs, true).unwrap();

        assert_eq!(fs::read(&outputs[0].destination).unwrap(), b"new-0");
        assert_eq!(fs::read(&outputs[1].destination).unwrap(), b"new-1");
        assert!(outputs.iter().all(|output| !output.backup.exists()));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn restores_every_existing_output_when_commit_fails() {
        let directory = test_directory("rollback");
        let outputs = [pending(&directory, 0), pending(&directory, 1)];
        fs::write(&outputs[0].destination, b"old-0").unwrap();
        fs::write(&outputs[1].destination, b"old-1").unwrap();
        fs::write(&outputs[0].temporary, b"new-0").unwrap();

        assert!(commit_outputs(&outputs, true).is_err());

        assert_eq!(fs::read(&outputs[0].destination).unwrap(), b"old-0");
        assert_eq!(fs::read(&outputs[1].destination).unwrap(), b"old-1");
        assert!(outputs.iter().all(|output| !output.backup.exists()));
        fs::remove_dir_all(directory).unwrap();
    }
}
