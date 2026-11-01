use crate::cancel::ScanToken;
use crate::cleaner::{passwd_home_dir, SystemArmor};
use crate::scanner::{calculate_dir_footprint_cancellable, calculate_file_footprint};
use crate::{PackageActionReport, RiskTier, RustDiskError, TerminalPackage};
use rayon::prelude::*;
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const GUI_PATH_PREFIX: &str =
    "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin";

#[derive(Clone, Copy)]
enum DiscoveryKind {
    HomebrewFormula,
    HomebrewCask,
    PythonConda,
    NodeJs,
    RustToolchain,
    ContainerVm,
}

struct DiscoveryRoot {
    manager: &'static str,
    base_path: PathBuf,
    kind: DiscoveryKind,
}

fn canonical_path(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn direct_entries(path: &Path, directories_only: bool) -> Vec<PathBuf> {
    fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|entry| !directories_only || entry.is_dir())
        .collect()
}

fn footprint(path: &Path, token: &ScanToken) -> (u64, u64) {
    if path.is_dir() {
        calculate_dir_footprint_cancellable(path, token)
    } else {
        calculate_file_footprint(path).unwrap_or((0, 0))
    }
}

fn version_directories(path: &Path) -> Vec<PathBuf> {
    direct_entries(path, true)
}

fn installed_on_request_from_receipts(version_paths: &[PathBuf]) -> bool {
    version_paths.iter().any(|version_path| {
        let receipt = version_path.join("INSTALL_RECEIPT.json");
        let Ok(contents) = fs::read_to_string(receipt) else {
            return false;
        };
        serde_json::from_str::<Value>(&contents)
            .ok()
            .and_then(|value| value.get("installed_on_request").and_then(Value::as_bool))
            .unwrap_or(false)
    })
}

fn package_from_measurement(
    path: &Path,
    name: String,
    manager: &'static str,
    physical_bytes: u64,
    logical_bytes: u64,
    version_count: u32,
    installed_on_request: bool,
    risk: RiskTier,
    uninstall_cmd: String,
) -> TerminalPackage {
    let canonical = canonical_path(path);
    TerminalPackage {
        id: canonical.to_string_lossy().into_owned(),
        name,
        manager: manager.to_owned(),
        path: canonical.to_string_lossy().into_owned(),
        physical_bytes,
        logical_bytes,
        version_count: version_count.max(1),
        installed_on_request,
        risk,
        uninstall_cmd,
    }
}

fn scan_homebrew_formula_root(root: &Path, token: &ScanToken) -> Vec<TerminalPackage> {
    direct_entries(root, true)
        .par_iter()
        .filter_map(|formula_path| {
            if token.is_cancelled() {
                return None;
            }
            let formula_name = formula_path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| "Unknown Formula".to_owned());
            let versions = version_directories(formula_path);
            let (physical_bytes, logical_bytes) = footprint(formula_path, token);
            let installed_on_request = installed_on_request_from_receipts(&versions);
            Some(package_from_measurement(
                formula_path,
                formula_name.clone(),
                "Homebrew Formula",
                physical_bytes,
                logical_bytes,
                versions.len() as u32,
                installed_on_request,
                RiskTier::HighRiskCli,
                format!("brew uninstall {formula_name}"),
            ))
        })
        .collect()
}

fn scan_homebrew_cask_root(root: &Path, token: &ScanToken) -> Vec<TerminalPackage> {
    direct_entries(root, true)
        .par_iter()
        .filter_map(|cask_path| {
            if token.is_cancelled() {
                return None;
            }
            let name = cask_path
                .file_name()
                .map(|value| value.to_string_lossy().into_owned())
                .unwrap_or_else(|| "Unknown Cask".to_owned());
            let versions = version_directories(cask_path);
            let (physical_bytes, logical_bytes) = footprint(cask_path, token);
            Some(package_from_measurement(
                cask_path,
                name.clone(),
                "Homebrew Cask",
                physical_bytes,
                logical_bytes,
                versions.len() as u32,
                true,
                RiskTier::HighRiskCli,
                format!("brew uninstall --cask {name}"),
            ))
        })
        .collect()
}

fn node_uninstall_command(path: &Path, name: &str) -> String {
    let path_string = path.to_string_lossy();
    if path_string.contains("/.nvm/versions/node/") {
        format!("nvm uninstall {name}")
    } else if path_string.contains("/fnm/node-versions/") {
        format!("fnm uninstall {name}")
    } else {
        format!("npm uninstall -g {name}")
    }
}

fn package_for_directory(
    path: &Path,
    manager: &'static str,
    kind: DiscoveryKind,
    token: &ScanToken,
) -> TerminalPackage {
    let name = path
        .file_name()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Unknown Package".to_owned());
    let (physical_bytes, logical_bytes) = footprint(path, token);
    let (installed_on_request, risk, uninstall_cmd) = match kind {
        DiscoveryKind::PythonConda => (
            true,
            RiskTier::Rebuildable,
            if path.to_string_lossy().contains("/.pyenv/versions/") {
                format!("pyenv uninstall -f {name}")
            } else if path.to_string_lossy().contains("/uv/python/") {
                format!("uv python uninstall {name}")
            } else {
                format!("conda remove -n {name} --all -y")
            },
        ),
        DiscoveryKind::NodeJs => (
            true,
            RiskTier::Rebuildable,
            node_uninstall_command(path, &name),
        ),
        DiscoveryKind::RustToolchain => (
            true,
            RiskTier::Rebuildable,
            format!("rustup toolchain uninstall {name}"),
        ),
        DiscoveryKind::ContainerVm => (
            true,
            RiskTier::HighRiskCli,
            "docker system prune -a --volumes -f".to_owned(),
        ),
        DiscoveryKind::HomebrewFormula | DiscoveryKind::HomebrewCask => {
            (true, RiskTier::HighRiskCli, String::new())
        }
    };

    package_from_measurement(
        path,
        name,
        manager,
        physical_bytes,
        logical_bytes,
        1,
        installed_on_request,
        risk,
        uninstall_cmd,
    )
}

fn scan_discovery_root(root: &DiscoveryRoot, token: &ScanToken) -> Vec<TerminalPackage> {
    if token.is_cancelled() || !root.base_path.exists() {
        return Vec::new();
    }
    match root.kind {
        DiscoveryKind::HomebrewFormula => scan_homebrew_formula_root(&root.base_path, token),
        DiscoveryKind::HomebrewCask => scan_homebrew_cask_root(&root.base_path, token),
        DiscoveryKind::ContainerVm => direct_entries(&root.base_path, false)
            .par_iter()
            .filter(|_| !token.is_cancelled())
            .map(|path| package_for_directory(path, root.manager, root.kind, token))
            .collect(),
        _ => direct_entries(&root.base_path, true)
            .par_iter()
            .filter(|path| {
                !(matches!(root.kind, DiscoveryKind::NodeJs)
                    && root.base_path.ends_with("lib/node_modules")
                    && path
                        .file_name()
                        .map(|name| matches!(name.to_string_lossy().as_ref(), "npm" | "corepack"))
                        .unwrap_or(false))
            })
            .filter(|_| !token.is_cancelled())
            .map(|path| package_for_directory(path, root.manager, root.kind, token))
            .collect(),
    }
}

fn standard_roots(home: &Path) -> Vec<DiscoveryRoot> {
    vec![
        DiscoveryRoot {
            manager: "Homebrew Formula",
            base_path: PathBuf::from("/opt/homebrew/Cellar"),
            kind: DiscoveryKind::HomebrewFormula,
        },
        DiscoveryRoot {
            manager: "Homebrew Formula",
            base_path: PathBuf::from("/usr/local/Cellar"),
            kind: DiscoveryKind::HomebrewFormula,
        },
        DiscoveryRoot {
            manager: "Homebrew Cask",
            base_path: PathBuf::from("/opt/homebrew/Caskroom"),
            kind: DiscoveryKind::HomebrewCask,
        },
        DiscoveryRoot {
            manager: "Homebrew Cask",
            base_path: PathBuf::from("/usr/local/Caskroom"),
            kind: DiscoveryKind::HomebrewCask,
        },
        DiscoveryRoot {
            manager: "Python & Conda",
            base_path: home.join(".pyenv/versions"),
            kind: DiscoveryKind::PythonConda,
        },
        DiscoveryRoot {
            manager: "Python & Conda",
            base_path: home.join("miniconda3/envs"),
            kind: DiscoveryKind::PythonConda,
        },
        DiscoveryRoot {
            manager: "Python & Conda",
            base_path: home.join("anaconda3/envs"),
            kind: DiscoveryKind::PythonConda,
        },
        DiscoveryRoot {
            manager: "Python & Conda",
            base_path: home.join("miniforge3/envs"),
            kind: DiscoveryKind::PythonConda,
        },
        DiscoveryRoot {
            manager: "Python & Conda",
            base_path: PathBuf::from("/opt/homebrew/Caskroom/miniconda/base/envs"),
            kind: DiscoveryKind::PythonConda,
        },
        DiscoveryRoot {
            manager: "Python & Conda",
            base_path: home.join(".local/share/uv/python"),
            kind: DiscoveryKind::PythonConda,
        },
        DiscoveryRoot {
            manager: "Python & Conda",
            base_path: home.join("Library/Application Support/uv/python"),
            kind: DiscoveryKind::PythonConda,
        },
        DiscoveryRoot {
            manager: "Node & JS",
            base_path: PathBuf::from("/opt/homebrew/lib/node_modules"),
            kind: DiscoveryKind::NodeJs,
        },
        DiscoveryRoot {
            manager: "Node & JS",
            base_path: PathBuf::from("/usr/local/lib/node_modules"),
            kind: DiscoveryKind::NodeJs,
        },
        DiscoveryRoot {
            manager: "Node & JS",
            base_path: home.join(".nvm/versions/node"),
            kind: DiscoveryKind::NodeJs,
        },
        DiscoveryRoot {
            manager: "Node & JS",
            base_path: home.join("Library/Application Support/fnm/node-versions"),
            kind: DiscoveryKind::NodeJs,
        },
        DiscoveryRoot {
            manager: "Node & JS",
            base_path: home.join(".local/share/fnm/node-versions"),
            kind: DiscoveryKind::NodeJs,
        },
        DiscoveryRoot {
            manager: "Rust Toolchain",
            base_path: home.join(".rustup/toolchains"),
            kind: DiscoveryKind::RustToolchain,
        },
        DiscoveryRoot {
            manager: "Container VM",
            base_path: home.join(".colima"),
            kind: DiscoveryKind::ContainerVm,
        },
        DiscoveryRoot {
            manager: "Container VM",
            base_path: home.join(".orbstack"),
            kind: DiscoveryKind::ContainerVm,
        },
    ]
}

fn docker_raw_package(home: &Path) -> Option<TerminalPackage> {
    let path = home.join("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw");
    let (physical_bytes, logical_bytes) = calculate_file_footprint(&path)?;
    Some(package_from_measurement(
        &path,
        "Docker.raw".to_owned(),
        "Container VM",
        physical_bytes,
        logical_bytes,
        1,
        true,
        RiskTier::HighRiskCli,
        "docker system prune -a --volumes -f".to_owned(),
    ))
}

fn scan_packages_from_roots(
    home: &Path,
    roots: Vec<DiscoveryRoot>,
    token: &ScanToken,
) -> Vec<TerminalPackage> {
    let mut packages: Vec<TerminalPackage> = roots
        .par_iter()
        .flat_map_iter(|root| scan_discovery_root(root, token))
        .collect();
    if token.is_cancelled() {
        return Vec::new();
    }
    if let Some(docker) = docker_raw_package(home) {
        packages.push(docker);
    }

    let mut seen = HashSet::new();
    packages.retain(|package| seen.insert(package.id.clone()));
    packages.retain(|package| package.physical_bytes > 0 || package.logical_bytes > 0);
    packages.sort_by(|left, right| right.physical_bytes.cmp(&left.physical_bytes));
    packages
}

/// Inspects Homebrew, Python/Conda, Node, Rust, and container runtime footprints.
#[uniffi::export]
pub fn scan_terminal_packages(home_dir: String) -> Vec<TerminalPackage> {
    let token = ScanToken::begin();
    crate::configure_scan_thread_pool();
    let home = PathBuf::from(home_dir);
    scan_packages_from_roots(&home, standard_roots(&home), &token)
}

fn gui_path(home: &Path) -> String {
    format!(
        "{GUI_PATH_PREFIX}:{}:{}",
        home.join(".cargo/bin").display(),
        home.join(".pyenv/shims").display()
    )
}

fn command_candidates(program: &str, home: &Path) -> Vec<PathBuf> {
    let mut candidates = match program {
        "brew" => vec![
            PathBuf::from("/opt/homebrew/bin/brew"),
            PathBuf::from("/usr/local/bin/brew"),
        ],
        "npm" => vec![
            PathBuf::from("/opt/homebrew/bin/npm"),
            PathBuf::from("/usr/local/bin/npm"),
        ],
        "pyenv" => vec![home.join(".pyenv/bin/pyenv")],
        "conda" => vec![
            home.join("miniconda3/bin/conda"),
            home.join("anaconda3/bin/conda"),
            home.join("miniforge3/bin/conda"),
            PathBuf::from("/opt/homebrew/bin/conda"),
        ],
        "uv" => vec![
            home.join(".local/bin/uv"),
            PathBuf::from("/opt/homebrew/bin/uv"),
        ],
        "rustup" => vec![home.join(".cargo/bin/rustup")],
        "docker" => vec![
            PathBuf::from("/usr/local/bin/docker"),
            PathBuf::from("/opt/homebrew/bin/docker"),
        ],
        _ => Vec::new(),
    };
    candidates.push(PathBuf::from(program));
    candidates
}

fn run_external(program: &str, args: &[String], home: &Path) -> Result<Output, String> {
    let mut last_error = None;
    for candidate in command_candidates(program, home) {
        match Command::new(&candidate)
            .args(args)
            .env("PATH", gui_path(home))
            .output()
        {
            Ok(output) => return Ok(output),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                last_error = Some(error.to_string());
            }
            Err(error) => return Err(format!("Failed to launch {program}: {error}")),
        }
    }
    Err(format!(
        "Failed to launch {program}: {}",
        last_error.unwrap_or_else(|| "command not found".to_owned())
    ))
}

fn command_display(program: &str, args: &[String]) -> String {
    std::iter::once(program.to_owned())
        .chain(args.iter().map(|arg| {
            if arg
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || "@%_+.-/".contains(character))
            {
                arg.clone()
            } else {
                format!("'{}'", arg.replace('\'', "'\\''"))
            }
        }))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Measures a path for uninstall reports. This is not a scan, so it ignores scan cancellation.
fn path_physical_bytes(path: &Path) -> u64 {
    footprint(path, &ScanToken::never()).0
}

fn action_report(
    command_run: String,
    before: u64,
    path: Option<&Path>,
    output: Output,
) -> PackageActionReport {
    let after = path.map(path_physical_bytes).unwrap_or(before);
    PackageActionReport {
        success: output.status.success(),
        command_run,
        freed_physical_bytes: before.saturating_sub(after),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}

fn direct_child_under(path: &Path, roots: &[PathBuf]) -> bool {
    let canonical_target = match fs::canonicalize(path) {
        Ok(path) => path,
        Err(_) => return false,
    };
    roots.iter().any(|root| {
        fs::canonicalize(root)
            .ok()
            .map(|root| {
                canonical_target.parent() == Some(root.as_path()) && canonical_target != root
            })
            .unwrap_or(false)
    })
}

fn validated_runtime_roots(manager: &str, home: &Path) -> Vec<PathBuf> {
    match manager {
        "Node & JS" => vec![
            home.join(".nvm/versions/node"),
            home.join("Library/Application Support/fnm/node-versions"),
            home.join(".local/share/fnm/node-versions"),
        ],
        "Python & Conda" => vec![
            home.join(".pyenv/versions"),
            home.join("miniconda3/envs"),
            home.join("anaconda3/envs"),
            home.join("miniforge3/envs"),
            home.join(".local/share/uv/python"),
            home.join("Library/Application Support/uv/python"),
            PathBuf::from("/opt/homebrew/Caskroom/miniconda/base/envs"),
        ],
        _ => Vec::new(),
    }
}

fn direct_removal_report(
    command_run: String,
    path: &Path,
    before: u64,
) -> Result<PackageActionReport, String> {
    // The path was already tied to a known runtime root, but deleting it
    // directly bypasses the package manager, so it also has to pass System Armor.
    SystemArmor::for_current_user()
        .check(path)
        .map_err(|reason| format!("Refusing to remove {}: {reason}", path.display()))?;
    fs::remove_dir_all(path).map_err(|error| {
        format!(
            "Failed to remove validated runtime directory {}: {error}",
            path.display()
        )
    })?;
    Ok(PackageActionReport {
        success: true,
        command_run,
        freed_physical_bytes: before.saturating_sub(path_physical_bytes(path)),
        stdout: String::new(),
        stderr: String::new(),
    })
}

fn current_home_dir() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|home| home.is_absolute())
        .or_else(passwd_home_dir)
        .ok_or_else(|| "Could not determine the current user's home directory.".to_owned())
}

const UNINSTALL_MANAGERS: [&str; 6] = [
    "Homebrew Formula",
    "Homebrew Cask",
    "Node & JS",
    "Python & Conda",
    "Rust Toolchain",
    "Container VM",
];

/// A package name becomes an argument to a package manager, so it must be a
/// plain identifier. Anything that could be read as an option or interpreted by
/// a tool (`-rf`, `--prefix=/`, `a;b`, `$(x)`, path separators) is refused.
///
/// Allowed: letters, digits, `-`, `_`, `.`, `@` (version pins such as
/// `python@3.12`) and `+` (real Homebrew names such as `gtk+3`). A name may not
/// start with `-`.
fn validate_package_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("Package name is empty.".to_owned());
    }
    if name.starts_with('-') {
        return Err(format!(
            "Package name {name:?} is not allowed: it must not start with '-'."
        ));
    }
    if name.chars().all(|character| character == '.') {
        return Err(format!("Package name {name:?} is not allowed."));
    }
    if let Some(bad) = name.chars().find(|character| {
        !(character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.' | '@' | '+'))
    }) {
        return Err(format!(
            "Package name {name:?} is not allowed: unsupported character {bad:?}."
        ));
    }
    Ok(())
}

/// The folders a package of this manager may live directly inside.
fn uninstall_roots(manager: &str, home: &Path) -> Vec<PathBuf> {
    match manager {
        "Homebrew Formula" => vec![
            PathBuf::from("/opt/homebrew/Cellar"),
            PathBuf::from("/usr/local/Cellar"),
        ],
        "Homebrew Cask" => vec![
            PathBuf::from("/opt/homebrew/Caskroom"),
            PathBuf::from("/usr/local/Caskroom"),
        ],
        "Node & JS" => {
            let mut roots = validated_runtime_roots(manager, home);
            roots.push(PathBuf::from("/opt/homebrew/lib/node_modules"));
            roots.push(PathBuf::from("/usr/local/lib/node_modules"));
            roots
        }
        "Python & Conda" => validated_runtime_roots(manager, home),
        "Rust Toolchain" => vec![home.join(".rustup/toolchains")],
        _ => Vec::new(),
    }
}

/// Container VM data may be anywhere below these folders (Docker.raw is nested deeply).
fn container_vm_roots(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(".colima"),
        home.join(".orbstack"),
        home.join("Library/Containers/com.docker.docker"),
    ]
}

/// True when `package_path` is a direct child of one of `roots` and
/// `<root>/<package_name>` resolves to that very path. The second condition ties
/// the name to the path, so a request cannot pair one package's path with
/// another's name. Symlinks are resolved, so a link that leaves the root fails
/// the first condition, while an alias such as `3.12 -> 3.12.0` still matches.
fn package_resolves_under_roots(
    package_name: &str,
    package_path: &Path,
    roots: &[PathBuf],
) -> bool {
    let Ok(target) = fs::canonicalize(package_path) else {
        return false;
    };
    roots.iter().any(|root| {
        let Ok(root) = fs::canonicalize(root) else {
            return false;
        };
        target.parent() == Some(root.as_path())
            && fs::canonicalize(root.join(package_name))
                .map(|named| named == target)
                .unwrap_or(false)
    })
}

fn path_is_strictly_within(path: &Path, roots: &[PathBuf]) -> bool {
    let Ok(target) = fs::canonicalize(path) else {
        return false;
    };
    roots.iter().any(|root| {
        fs::canonicalize(root)
            .map(|root| target != root && target.starts_with(&root))
            .unwrap_or(false)
    })
}

/// Rejects any uninstall request that does not describe a package this app
/// could have discovered. Runs before any command is started.
fn validate_uninstall_request(
    manager: &str,
    package_name: &str,
    package_path: &Path,
    home: &Path,
) -> Result<(), String> {
    if !UNINSTALL_MANAGERS.contains(&manager) {
        return Err(format!("Unsupported package manager: {manager}"));
    }

    if manager == "Container VM" {
        // The name is never passed to a command here (the action is a fixed
        // `docker system prune`), and Colima/OrbStack entries can have names
        // that are not package identifiers.
        if package_name.is_empty() || package_name.contains('\0') {
            return Err("Package name is empty or contains an invalid NUL character.".to_owned());
        }
        if !path_is_strictly_within(package_path, &container_vm_roots(home)) {
            return Err(format!(
                "Path {} is not inside a known container runtime folder.",
                package_path.display()
            ));
        }
        return Ok(());
    }

    validate_package_name(package_name)?;
    if !package_resolves_under_roots(package_name, package_path, &uninstall_roots(manager, home)) {
        return Err(format!(
            "Path {} is not where {manager} installs {package_name:?}.",
            package_path.display()
        ));
    }
    Ok(())
}

/// Safely uninstalls a discovered package or runtime and reports measured physical bytes.
fn run_terminal_uninstall_impl(
    manager: String,
    package_name: String,
    path: String,
) -> Result<PackageActionReport, String> {
    let home = current_home_dir()?;
    let package_path = PathBuf::from(&path);
    validate_uninstall_request(&manager, &package_name, &package_path, &home)?;
    let before = path_physical_bytes(&package_path);

    if manager == "Container VM" {
        let args = vec![
            "system".to_owned(),
            "prune".to_owned(),
            "-a".to_owned(),
            "--volumes".to_owned(),
            "-f".to_owned(),
        ];
        let output = run_external("docker", &args, &home)?;
        return Ok(action_report(
            command_display("docker", &args),
            before,
            Some(&package_path),
            output,
        ));
    }

    if matches!(manager.as_str(), "Node & JS" | "Python & Conda")
        && direct_child_under(&package_path, &validated_runtime_roots(&manager, &home))
    {
        let program = if manager == "Node & JS" {
            if path.contains("/.nvm/versions/node/") {
                "nvm"
            } else {
                "fnm"
            }
        } else if path.contains("/.pyenv/versions/") {
            "pyenv"
        } else if path.contains("/uv/python/") {
            "uv"
        } else {
            "conda"
        };
        let command_run = format!("{program} uninstall {package_name}");
        let (command, args) = match (manager.as_str(), program) {
            ("Node & JS", "nvm") => ("nvm", vec!["uninstall".to_owned(), package_name.clone()]),
            ("Node & JS", _) => ("fnm", vec!["uninstall".to_owned(), package_name.clone()]),
            ("Python & Conda", "pyenv") => (
                "pyenv",
                vec![
                    "uninstall".to_owned(),
                    "-f".to_owned(),
                    package_name.clone(),
                ],
            ),
            ("Python & Conda", "uv") => (
                "uv",
                vec![
                    "python".to_owned(),
                    "uninstall".to_owned(),
                    package_name.clone(),
                ],
            ),
            _ => (
                "conda",
                vec![
                    "remove".to_owned(),
                    "-n".to_owned(),
                    package_name.clone(),
                    "--all".to_owned(),
                    "-y".to_owned(),
                ],
            ),
        };
        match run_external(command, &args, &home) {
            Ok(output) => {
                return Ok(action_report(
                    command_display(command, &args),
                    before,
                    Some(&package_path),
                    output,
                ));
            }
            Err(_) => {
                // nvm/fnm are commonly shell functions and GUI apps may not inherit
                // their shims. The path was validated as one child of a known root.
                return direct_removal_report(command_run, &package_path, before);
            }
        }
    }

    let (program, args, command_run, run_cleanup) = match manager.as_str() {
        "Homebrew Formula" => {
            let args = vec!["uninstall".to_owned(), package_name.clone()];
            (
                "brew",
                args,
                format!("brew uninstall {package_name} && brew cleanup -s {package_name}"),
                true,
            )
        }
        "Homebrew Cask" => {
            let args = vec![
                "uninstall".to_owned(),
                "--cask".to_owned(),
                package_name.clone(),
            ];
            ("brew", args.clone(), command_display("brew", &args), false)
        }
        "Node & JS" => {
            let args = vec![
                "uninstall".to_owned(),
                "-g".to_owned(),
                package_name.clone(),
            ];
            ("npm", args.clone(), command_display("npm", &args), false)
        }
        "Python & Conda" => {
            let args = vec![
                "remove".to_owned(),
                "-n".to_owned(),
                package_name.clone(),
                "--all".to_owned(),
                "-y".to_owned(),
            ];
            (
                "conda",
                args.clone(),
                command_display("conda", &args),
                false,
            )
        }
        "Rust Toolchain" => {
            let args = vec![
                "toolchain".to_owned(),
                "uninstall".to_owned(),
                package_name.clone(),
            ];
            (
                "rustup",
                args.clone(),
                command_display("rustup", &args),
                false,
            )
        }
        _ => return Err(format!("Unsupported package manager: {manager}")),
    };

    let output = run_external(program, &args, &home)?;
    if !output.status.success() {
        return Ok(action_report(
            command_run,
            before,
            Some(&package_path),
            output,
        ));
    }

    if run_cleanup {
        let cleanup_args = vec!["cleanup".to_owned(), "-s".to_owned(), package_name];
        let cleanup_output = run_external("brew", &cleanup_args, &home)?;
        let mut report = action_report(command_run, before, Some(&package_path), output);
        report.success = cleanup_output.status.success();
        report
            .stdout
            .push_str(&String::from_utf8_lossy(&cleanup_output.stdout));
        report
            .stderr
            .push_str(&String::from_utf8_lossy(&cleanup_output.stderr));
        report.freed_physical_bytes = before.saturating_sub(path_physical_bytes(&package_path));
        return Ok(report);
    }

    Ok(action_report(
        command_run,
        before,
        Some(&package_path),
        output,
    ))
}

/// Runs a supported global maintenance command and measures available physical space change.
fn run_package_maintenance_impl(action: String) -> Result<PackageActionReport, String> {
    let home = current_home_dir()?;
    let (program, args) = match action.as_str() {
        "brew_cleanup" => ("brew", vec!["cleanup".to_owned(), "--prune=all".to_owned()]),
        "brew_autoremove" => ("brew", vec!["autoremove".to_owned()]),
        "docker_prune" => (
            "docker",
            vec![
                "system".to_owned(),
                "prune".to_owned(),
                "-a".to_owned(),
                "--volumes".to_owned(),
                "-f".to_owned(),
            ],
        ),
        _ => return Err(format!("Unsupported maintenance action: {action}")),
    };

    let before = crate::get_disk_overview().available_bytes;
    let output = run_external(program, &args, &home)?;
    let after = crate::get_disk_overview().available_bytes;
    Ok(PackageActionReport {
        success: output.status.success(),
        command_run: command_display(program, &args),
        freed_physical_bytes: after.saturating_sub(before),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

#[uniffi::export]
pub fn run_terminal_uninstall(
    manager: String,
    package_name: String,
    path: String,
) -> Result<PackageActionReport, RustDiskError> {
    run_terminal_uninstall_impl(manager, package_name, path).map_err(RustDiskError::message)
}

#[uniffi::export]
pub fn run_package_maintenance(action: String) -> Result<PackageActionReport, RustDiskError> {
    run_package_maintenance_impl(action).map_err(RustDiskError::message)
}

#[cfg(test)]
mod tests {
    use super::{
        docker_raw_package, package_resolves_under_roots, run_package_maintenance_impl,
        run_terminal_uninstall_impl, scan_discovery_root, scan_homebrew_formula_root,
        scan_packages_from_roots, uninstall_roots, validate_package_name,
        validate_uninstall_request, DiscoveryKind, DiscoveryRoot,
    };
    use crate::cancel::ScanToken;
    use crate::cleaner::purge_items;
    use crate::{DeletionMode, RiskTier};
    use std::fs::{self, File};
    use std::io::{Seek, SeekFrom, Write};
    use std::os::unix::fs::symlink;
    use std::path::{Path, PathBuf};

    #[test]
    fn homebrew_receipts_report_request_status_versions_and_footprint() {
        let root = temp_root("formula-receipts");
        let formula = root.join("openssl@3");
        let v1 = formula.join("3.1.0");
        let v2 = formula.join("3.2.0");
        fs::create_dir_all(&v1).unwrap();
        fs::create_dir_all(&v2).unwrap();
        write_bytes(
            &v1.join("INSTALL_RECEIPT.json"),
            br#"{"installed_on_request":false}"#,
        );
        write_bytes(
            &v2.join("INSTALL_RECEIPT.json"),
            br#"{"installed_on_request":true}"#,
        );
        write_bytes(&v1.join("lib.bin"), &vec![0u8; 8192]);
        write_bytes(&v2.join("lib.bin"), &vec![0u8; 8192]);

        let packages = scan_homebrew_formula_root(&root, &ScanToken::never());
        assert_eq!(packages.len(), 1);
        assert_eq!(packages[0].version_count, 2);
        assert!(packages[0].installed_on_request);
        assert!(packages[0].physical_bytes > 0);
        assert!(packages[0].logical_bytes >= 16 * 1024);

        remove_root(root);
    }

    #[test]
    fn multi_manager_roots_use_safe_labels_and_commands() {
        let root = temp_root("manager-discovery");
        let pyenv = root.join(".pyenv/versions");
        let nvm = root.join(".nvm/versions/node");
        let rustup = root.join(".rustup/toolchains");
        for path in [&pyenv, &nvm, &rustup] {
            fs::create_dir_all(path).unwrap();
        }
        write_bytes(&pyenv.join("3.12.0/libpython"), &vec![0u8; 8192]);
        write_bytes(&nvm.join("v22.0.0/bin/node"), &vec![0u8; 8192]);
        write_bytes(&rustup.join("stable-aarch64/bin/rustc"), &vec![0u8; 8192]);

        let python = scan_discovery_root(
            &DiscoveryRoot {
                manager: "Python & Conda",
                base_path: pyenv,
                kind: DiscoveryKind::PythonConda,
            },
            &ScanToken::never(),
        );
        let node = scan_discovery_root(
            &DiscoveryRoot {
                manager: "Node & JS",
                base_path: nvm,
                kind: DiscoveryKind::NodeJs,
            },
            &ScanToken::never(),
        );
        let rust = scan_discovery_root(
            &DiscoveryRoot {
                manager: "Rust Toolchain",
                base_path: rustup,
                kind: DiscoveryKind::RustToolchain,
            },
            &ScanToken::never(),
        );
        assert_eq!(python[0].manager, "Python & Conda");
        assert!(python[0].uninstall_cmd.starts_with("pyenv uninstall"));
        assert_eq!(node[0].manager, "Node & JS");
        assert!(node[0].uninstall_cmd.starts_with("nvm uninstall"));
        assert_eq!(rust[0].manager, "Rust Toolchain");
        assert!(rust[0]
            .uninstall_cmd
            .starts_with("rustup toolchain uninstall"));

        remove_root(root);
    }

    #[test]
    fn package_names_must_be_plain_identifiers() {
        for name in [
            "openssl@3",
            "python@3.12",
            "gtk+3",
            "libsigc++@2",
            "font-fira-code",
            "node_modules",
            "v22.0.0",
            "3.12.0",
            "stable-aarch64-apple-darwin",
            "cpython-3.12.1-macos-aarch64-none",
        ] {
            assert!(
                validate_package_name(name).is_ok(),
                "{name} should be accepted"
            );
        }

        for name in [
            "",
            "-rf",
            "-rf /",
            "--force",
            "--prefix=/",
            "-",
            ".",
            "..",
            "a b",
            "a;rm",
            "a&&b",
            "a|b",
            "$(whoami)",
            "`id`",
            "a/b",
            "../etc",
            "a\nb",
            "a\0b",
            "name'quote",
            "name\"quote",
            "tab\tname",
        ] {
            assert!(
                validate_package_name(name).is_err(),
                "{name:?} should be rejected"
            );
        }
    }

    #[test]
    fn injected_names_are_refused_before_any_command_could_run() {
        for name in ["-rf", "--force", "-rf /", "$(whoami)", "a;b"] {
            let error = run_terminal_uninstall_impl(
                "Homebrew Formula".to_owned(),
                name.to_owned(),
                format!("/opt/homebrew/Cellar/{name}"),
            )
            .unwrap_err();
            assert!(error.contains("is not allowed"), "{name:?}: {error}");
        }
    }

    #[test]
    fn uninstall_paths_must_resolve_to_the_named_package_directly_under_a_root() {
        let root = temp_root("uninstall-paths");
        let versions = root.join("versions");
        write_bytes(&versions.join("3.12.0/bin/python"), b"x");
        write_bytes(&versions.join("3.11.0/bin/python"), b"x");
        write_bytes(&root.join("outside/payload"), b"x");
        symlink(versions.join("3.12.0"), versions.join("3.12")).unwrap();
        symlink(root.join("outside"), versions.join("escape")).unwrap();

        let roots = vec![versions.clone()];
        let matches = |name: &str, path: &Path| package_resolves_under_roots(name, path, &roots);

        assert!(matches("3.12.0", &versions.join("3.12.0")));
        assert!(
            matches("3.12", &versions.join("3.12.0")),
            "an alias that resolves to the same directory is the same package"
        );
        assert!(
            !matches("3.11.0", &versions.join("3.12.0")),
            "another package's name with this path"
        );
        assert!(
            !matches("3.12.0", &root.join("outside")),
            "outside the root"
        );
        assert!(
            !matches("escape", &root.join("outside")),
            "a symlink that leaves the root"
        );
        assert!(!matches("3.13.0", &versions.join("3.13.0")), "missing");
        assert!(!matches("..", &root), "traversal through the name");

        remove_root(root);
    }

    #[test]
    fn validation_ties_each_manager_to_its_own_roots() {
        let home = temp_root("uninstall-home");
        write_bytes(&home.join(".pyenv/versions/3.12.0/bin/python"), b"x");
        write_bytes(&home.join(".rustup/toolchains/stable/bin/rustc"), b"x");
        write_bytes(&home.join(".colima/default/diffdisk"), b"x");
        write_bytes(&home.join("Documents/3.12.0/notes.txt"), b"x");

        let python = home.join(".pyenv/versions/3.12.0");
        let check = |manager: &str, name: &str, path: &Path| {
            validate_uninstall_request(manager, name, path, &home)
        };
        assert!(check("Python & Conda", "3.12.0", &python).is_ok());
        assert!(check(
            "Rust Toolchain",
            "stable",
            &home.join(".rustup/toolchains/stable")
        )
        .is_ok());
        // The right name and a real folder, but not in this manager's root.
        assert!(check("Python & Conda", "3.12.0", &home.join("Documents/3.12.0")).is_err());
        // A real path of one manager presented as another manager's package.
        assert!(check("Rust Toolchain", "3.12.0", &python).is_err());
        assert!(check("Python & Conda", "--all", &python).is_err());
        assert!(check("Python & Conda", "3.11.0", &python).is_err());
        assert!(check("Unknown Manager", "3.12.0", &python)
            .unwrap_err()
            .contains("Unsupported package manager"));

        let colima = home.join(".colima");
        assert!(check("Container VM", "default", &colima.join("default")).is_ok());
        assert!(
            check("Container VM", "default", &colima).is_err(),
            "the root itself"
        );
        assert!(check("Container VM", "default", &home.join("Documents")).is_err());
        assert!(check("Container VM", "default", Path::new("/etc/hosts")).is_err());

        remove_root(home);
    }

    #[test]
    fn homebrew_packages_must_sit_directly_in_the_cellar_or_caskroom() {
        let home = Path::new("/Users/test");
        assert_eq!(
            uninstall_roots("Homebrew Formula", home),
            [
                PathBuf::from("/opt/homebrew/Cellar"),
                PathBuf::from("/usr/local/Cellar")
            ]
        );
        assert_eq!(
            uninstall_roots("Homebrew Cask", home),
            [
                PathBuf::from("/opt/homebrew/Caskroom"),
                PathBuf::from("/usr/local/Caskroom")
            ]
        );

        for (manager, name, path) in [
            (
                "Homebrew Formula",
                "openssl@3",
                "/Users/test/Documents/openssl@3",
            ),
            (
                "Homebrew Formula",
                "brew",
                "/opt/homebrew/Cellar/../bin/brew",
            ),
            ("Homebrew Formula", "x", "/etc/hosts"),
            (
                "Homebrew Formula",
                "nonexistent-rustdisk-test",
                "/opt/homebrew/Cellar/nonexistent-rustdisk-test",
            ),
            ("Homebrew Cask", "firefox", "/Applications/Firefox.app"),
        ] {
            assert!(
                validate_uninstall_request(manager, name, Path::new(path), home).is_err(),
                "{manager} {name} {path}"
            );
        }
    }

    #[test]
    fn cancelled_package_scan_returns_nothing() {
        let root = temp_root("cancelled-packages");
        let formula = root.join(".rustup/toolchains/stable-aarch64");
        write_bytes(&formula.join("bin/rustc"), &vec![0u8; 8192]);
        let roots = || {
            vec![DiscoveryRoot {
                manager: "Rust Toolchain",
                base_path: root.join(".rustup/toolchains"),
                kind: DiscoveryKind::RustToolchain,
            }]
        };

        let live = scan_packages_from_roots(&root, roots(), &ScanToken::never());
        assert_eq!(live.len(), 1);

        let cancelled = ScanToken::never();
        cancelled.cancel();
        assert!(scan_packages_from_roots(&root, roots(), &cancelled).is_empty());

        remove_root(root);
    }

    #[test]
    fn sparse_docker_disk_reports_logical_and_physical_bytes_and_is_protected() {
        let root = temp_root("docker-sparse");
        fs::create_dir_all(&root).unwrap();
        let path = root.join("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut file = File::create(&path).unwrap();
        file.set_len(64 * 1024 * 1024).unwrap();
        file.seek(SeekFrom::Start(0)).unwrap();
        file.write_all(&vec![0u8; 4096]).unwrap();
        file.flush().unwrap();

        let package = docker_raw_package(&root).unwrap();
        assert!(package.logical_bytes >= 64 * 1024 * 1024);
        assert!(package.physical_bytes > 0);
        assert_eq!(package.risk, RiskTier::HighRiskCli);
        let report = purge_items(
            vec![path.to_string_lossy().into_owned()],
            DeletionMode::PermanentDelete,
        );
        assert!(!report.errors.is_empty());
        assert!(path.exists());

        remove_root(root);
    }

    #[test]
    fn unsupported_commands_fail_with_descriptive_errors() {
        let uninstall = run_terminal_uninstall_impl(
            "Unsupported Manager".to_owned(),
            "demo".to_owned(),
            "/tmp/demo".to_owned(),
        );
        assert!(uninstall
            .unwrap_err()
            .contains("Unsupported package manager"));
        let maintenance = run_package_maintenance_impl("not_real".to_owned());
        assert!(maintenance
            .unwrap_err()
            .contains("Unsupported maintenance action"));
    }

    fn write_bytes(path: &std::path::Path, bytes: &[u8]) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        File::create(path).unwrap().write_all(bytes).unwrap();
    }

    fn temp_root(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("rustdisk-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        path
    }

    fn remove_root(root: PathBuf) {
        fs::remove_dir_all(root).unwrap();
    }
}
