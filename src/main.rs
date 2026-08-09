use clap::{ArgAction, Parser};
use indicatif::{ProgressBar, ProgressStyle};
use std::path::PathBuf;
use std::time::Duration;
use stemcraft::pipeline::{Event, Pipeline, Product, Reporter};

struct TerminalReporter(Option<ProgressBar>);

impl TerminalReporter {
    fn new() -> Self {
        Self(None)
    }

    fn clear(&mut self) {
        if let Some(spinner) = self.0.take() {
            spinner.finish_and_clear();
        }
    }
}

impl Reporter for TerminalReporter {
    fn report(&mut self, event: Event) {
        match event {
            Event::StageStarted(label) => {
                self.clear();
                let spinner = ProgressBar::new_spinner();
                spinner.set_style(ProgressStyle::with_template("{spinner:.cyan} {msg}").unwrap());
                spinner.enable_steady_tick(Duration::from_millis(90));
                spinner.set_message(label);
                self.0 = Some(spinner);
            }
            Event::StageProgress { detail, percent } => {
                if let Some(progress) = self.0.as_ref() {
                    if let Some(percent) = percent {
                        progress.set_length(100);
                        progress.set_position(percent);
                        progress.set_style(
                            ProgressStyle::with_template("{bar:24.cyan/dim} {pos:>3}% {msg}")
                                .unwrap()
                                .progress_chars("━━╸"),
                        );
                    }
                    progress.set_message(detail);
                }
            }
            Event::StageCompleted(label) => {
                if let Some(spinner) = self.0.take() {
                    spinner.finish_with_message(format!("✓ {label}"));
                }
            }
        }
    }
}

#[derive(Parser, Debug)]
#[command(
    name = "stemcraft",
    version,
    about = "Create DJ-ready stems from a full mix"
)]
struct Cli {
    /// Create only an acapella
    #[arg(short = 'a', long, action = ArgAction::SetTrue, conflicts_with = "instrumental")]
    acapella: bool,

    /// Create only an instrumental
    #[arg(short = 'i', long, action = ArgAction::SetTrue)]
    instrumental: bool,

    /// Source audio file
    #[arg(value_name = "TRACK")]
    track: PathBuf,
}

fn main() {
    let cli = Cli::parse();
    let products = if cli.acapella {
        vec![Product::Acapella]
    } else if cli.instrumental {
        vec![Product::Instrumental]
    } else {
        vec![Product::Acapella, Product::Instrumental]
    };

    println!("Stemcraft\n");
    let mut reporter = TerminalReporter::new();
    let result = Pipeline::preflight()
        .and_then(|_| Pipeline::new(&cli.track))
        .and_then(|pipeline| pipeline.run(&products, &mut reporter));
    reporter.clear();

    match result {
        Ok(outputs) => {
            println!(
                "\nDone — created {} file{}:",
                outputs.len(),
                if outputs.len() == 1 { "" } else { "s" }
            );
            for output in outputs {
                println!("  {}", output.display());
            }
        }
        Err(error) => {
            eprintln!("\nCouldn’t finish: {}", error.message);
            if let Some(guidance) = error.guidance {
                eprintln!("\nTry this: {guidance}");
            }
            std::process::exit(1);
        }
    }
}
