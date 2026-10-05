#!/data/data/com.termux/files/usr/bin/bash
#
# Freebuff for Termux — diagnostics
#
# Collects and interprets everything needed to tell whether this port can run on
# this device. Output is plain text so it can be pasted straight into an issue.
#
# This port was developed without access to Android hardware, so this script is
# how a real device reports back what actually happens. When reporting a problem,
# this output is the first thing to include.
#
# Usage:
#   freebuff-diagnose            full report
#   freebuff-diagnose --short    environment and exec test only
#   freebuff-diagnose --redact   omit paths and the device model
#
#   License: Apache-2.0.

set -u

SHORT=0
REDACT=0
for arg in "$@"; do
	case "${arg}" in
		--short)  SHORT=1 ;;
		--redact) REDACT=1 ;;
		-h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) printf 'diagnose: unknown argument: %s\n' "${arg}" >&2; exit 2 ;;
	esac
done

PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
CONFIG_DIR="${FREEBUFF_TERMUX_CONFIG_DIR:-${HOME}/.config/manicode}"
BINARY="${FREEBUFF_TERMUX_BINARY:-${PREFIX_DIR}/libexec/freebuff/freebuff}"
WASM="$(dirname "${BINARY}")/tree-sitter.wasm"

PROBLEMS=""
NOTE() { PROBLEMS="${PROBLEMS}  - $1"$'\n'; }
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n== %s ==\n' "$1"; }
kv() { printf '%-24s %s\n' "$1" "$2"; }
have_line() { if have "$1"; then kv "$1" "$(command -v "$1")"; else kv "$1" "MISSING"; fi; }
redact() { if [ "${REDACT}" -eq 1 ]; then printf '<%s>' "$(printf '%s' "$1" | sed 's|.*/||')"; else printf '%s' "$1"; fi; }

# --- device and runtime -----------------------------------------------------

section "device"
kv "architecture" "$(uname -m)"
kv "kernel" "$(uname -r)"
if have getprop; then
	kv "android" "$(getprop ro.build.version.release 2>/dev/null || echo '?')"
	kv "android sdk" "$(getprop ro.build.version.sdk 2>/dev/null || echo '?')"
	kv "cpu abi" "$(getprop ro.product.cpu.abi 2>/dev/null || echo '?')"
	kv "device" "$(redact "$(getprop ro.product.model 2>/dev/null || echo '?')")"
else
	kv "android" "getprop unavailable -- not Termux?"
fi
kv "PREFIX" "$(redact "${PREFIX_DIR}")"

# Android 15 introduced 16 KiB memory pages, and a binary whose segments are not
# 16 KiB aligned cannot be loaded there at all. OpenTUI's Android build is
# specifically aligned for this, so a failure here points at the packaging rather
# than at Freebuff.
PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo '?')"
kv "page size" "${PAGE_SIZE}"
if [ "${PAGE_SIZE}" = "16384" ]; then
	printf '  (16 KiB pages: this device needs a 16 KiB-aligned build)\n'
fi

if [ "$(uname -m)" != "aarch64" ]; then
	NOTE "This port is aarch64-only. Bun and OpenTUI publish no 32-bit Android build; use proot-distro on a 32-bit device."
fi

section "terminal"
kv "TERM" "${TERM:-<unset>}"
kv "COLORTERM" "${COLORTERM:-<unset>}"
kv "size" "$(stty size 2>/dev/null || echo '?')"
case "${TERM:-}" in
	xterm-256color|alacritty|kitty|foot|wezterm|ghostty|tmux-256color|screen*|xterm*) : ;;
	*) NOTE "TERM='${TERM:-unset}' is outside what OpenTUI handles well. Try: export TERM=xterm-256color" ;;
esac

# --- install state ----------------------------------------------------------

section "install"
if have dpkg-query; then
	kv "package version" "$(dpkg-query -W -f='${Version}' freebuff 2>/dev/null || echo 'not installed via dpkg')"
fi
[ -f "${PREFIX_DIR}/share/freebuff/version" ] &&
	kv "stamped version" "$(cat "${PREFIX_DIR}/share/freebuff/version")"
[ -f "${PREFIX_DIR}/share/freebuff/upstream-commit" ] &&
	kv "upstream commit" "$(cat "${PREFIX_DIR}/share/freebuff/upstream-commit")"

if [ -f "${BINARY}" ]; then
	kv "binary" "$(redact "${BINARY}")"
	kv "size" "$(wc -c < "${BINARY}" 2>/dev/null | tr -d ' ') bytes"
	kv "sha256" "$(sha256sum "${BINARY}" 2>/dev/null | cut -c1-64)"
	[ -x "${BINARY}" ] && kv "executable" "yes" || {
		kv "executable" "NO"
		NOTE "Not executable. Android refuses to exec from /sdcard and any noexec mount; the binary must live in \$PREFIX."
	}
	# The CLI extracts its own ripgrep next to the binary, so the directory must
	# be writable.
	if [ -w "$(dirname "${BINARY}")" ]; then
		kv "libexec writable" "yes"
	else
		kv "libexec writable" "NO"
		NOTE "$(dirname "${BINARY}") is not writable. Reinstall as root-owned via dpkg, or copy the tree somewhere writable."
	fi
else
	kv "binary" "MISSING at $(redact "${BINARY}")"
	NOTE "No binary. Reinstall: curl -fsSL <install-url> | bash"
fi

# The CLI reads this from its own directory at startup; a missing asset costs
# syntax highlighting, not startup.
if [ -f "${WASM}" ]; then
	kv "tree-sitter.wasm" "present beside the binary"
else
	kv "tree-sitter.wasm" "MISSING"
	NOTE "tree-sitter.wasm must sit next to the binary (dirname(process.execPath)). Syntax highlighting will fail without it."
fi

[ "${SHORT}" -eq 1 ] && { printf '\n(--short: stopping before the ELF and exec tests)\n'; exit 0; }

# --- ELF analysis ------------------------------------------------------------
#
# The decisive property of this port: the binary must be a Bionic executable.
# A glibc or musl binary reports a different PT_INTERP, and there is no way to
# run it on Android -- so this is checked explicitly rather than inferred from
# "it ran".

section "elf"
if [ -f "${BINARY}" ]; then
	MAGIC="$(od -An -tx1 -N4 "${BINARY}" 2>/dev/null | tr -d ' \n')"
	if [ "${MAGIC}" = "7f454c46" ]; then
		kv "format" "ELF"
		CLASS_BYTE="$(od -An -tx1 -j4 -N1 "${BINARY}" 2>/dev/null | tr -d ' \n')"
		[ "${CLASS_BYTE}" = "02" ] && kv "class" "64-bit" || kv "class" "byte ${CLASS_BYTE}"
		MACHINE="$(od -An -tx1 -j18 -N2 "${BINARY}" 2>/dev/null | tr -d ' \n')"
		case "${MACHINE}" in
			b7) kv "machine" "AArch64 (ok)" ;;
			3e) kv "machine" "x86-64 (WRONG)"; NOTE "This is an x86-64 binary; it cannot run on aarch64." ;;
			*)  kv "machine" "${MACHINE:-unknown}" ;;
		esac

		if have readelf; then
			INTERP="$(readelf -lW "${BINARY}" 2>/dev/null | awk '/INTERP/{getline; print $NF}' | head -n1)"
			[ -n "${INTERP}" ] && kv "interpreter" "${INTERP}" || kv "interpreter" "none (static)"
			case "${INTERP}" in
				/system/bin/linker*) kv "libc" "Bionic (correct)" ;;
				/lib/ld-musl*)      kv "libc" "musl"; NOTE "musl binary: Android's linker is Bionic and cannot load this. Rebuild against the Android target." ;;
				/lib64/ld-linux*)   kv "libc" "glibc"; NOTE "glibc binary: this is a stock Freebuff release, which cannot run on Android. Install the .deb from this project." ;;
				"")                 : ;;
				*)                  kv "libc" "unknown interpreter" ;;
			esac
			kv "NEEDED libs" "$(readelf -dW "${BINARY}" 2>/dev/null | awk '/NEEDED/{print $NF}' | tr '\n' ' ')"
			# Android 15 devices may use 16 KiB memory pages. Every PT_LOAD's p_align
			# must be a multiple of the page size or the loader refuses the image.
			# Done with shell arithmetic rather than awk: Termux's awk is busybox
			# awk, which has no strtonum(), and that would silently report "ok".
			if [ "${PAGE_SIZE}" = "16384" ]; then
				MISALIGNED=0
				ALIGNS="$(readelf -lW "${BINARY}" 2>/dev/null | awk '$1 == "LOAD" { print $NF }')"
				for align in ${ALIGNS}; do
					align="${align%]}"
					value=$(( align )) 2>/dev/null || continue
					[ $(( value % 16384 )) -ne 0 ] && MISALIGNED=$(( MISALIGNED + 1 ))
				done
				if [ "${MISALIGNED}" -gt 0 ]; then
					NOTE "${MISALIGNED} PT_LOAD segment(s) are not 16 KiB aligned; this binary cannot load on a 16 KiB-page device."
				else
					kv "16 KiB alignment" "ok"
				fi
			fi
		else
			kv "interpreter" "unknown -- install binutils for readelf (pkg install binutils)"
			NOTE "Without readelf the Bionic check cannot be made. pkg install binutils"
		fi
	else
		kv "format" "not an ELF file"
		NOTE "The binary is not an ELF executable. The install is corrupt."
	fi
else
	kv "format" "no binary to inspect"
fi

# --- native module -----------------------------------------------------------
#
# OpenTUI's renderer is a Zig library loaded through Bun FFI. This port uses the
# Android build (@androidtui/core-android-arm64), which is compiled into the
# binary. There is nothing to check on disk -- if it is missing, the process
# fails at dlopen, which the exec test below catches.

section "opentui"
kv "OPENTUI_LIBC" "${OPENTUI_LIBC:-<unset>}"
printf '  (not needed here: the Android build is selected by platform, not by libc)\n'
if [ -d "${CONFIG_DIR}" ]; then
	# The per-launch extracted library, if the wrapper's sweep has not run yet.
	LEAKED="$(find "${TMPDIR:-${PREFIX_DIR}/tmp}" -maxdepth 1 -name '.*.so' -type f 2>/dev/null | wc -l | tr -d ' ')"
	kv "leaked .so files" "${LEAKED}"
	[ "${LEAKED}" -gt 5 ] && NOTE \
		"${LEAKED} extracted libopentui copies in TMPDIR (upstream issue 1443, still open). The wrapper sweeps them each launch; this count is from runs that bypassed it."
fi

# --- CA certificates ---------------------------------------------------------

section "certificates"
CA_BUNDLE="${PREFIX_DIR}/etc/tls/certs/ca-certificates.crt"
if [ -r "${CA_BUNDLE}" ]; then
	kv "ca-certificates" "$(redact "${CA_BUNDLE}")"
else
	kv "ca-certificates" "MISSING"
	NOTE "No CA bundle. Bun has its own root store so this is usually survivable, but a proxy with a private CA will fail. pkg install ca-certificates"
fi
kv "NODE_EXTRA_CA_CERTS" "${NODE_EXTRA_CA_CERTS:-<unset>}"

# --- ripgrep ------------------------------------------------------------------

section "ripgrep"
if have rg; then
	RG="$(command -v rg)"
	kv "rg on PATH" "$(redact "${RG}")"
	if "${RG}" --version >/dev/null 2>&1; then
		kv "rg works" "yes ($("${RG}" --version 2>/dev/null | head -n1))"
	else
		kv "rg works" "NO"; NOTE "rg is on PATH but does not run. File-finding will fail."
	fi
else
	kv "rg on PATH" "MISSING"
	NOTE "ripgrep is not installed, so code search and the file-finding agents are disabled. pkg install ripgrep"
fi
kv "CODEBUFF_RG_PATH" "${CODEBUFF_RG_PATH:-<unset>}"
# A glibc rg extracted next to the binary means patch "ripgrep: honour
# CODEBUFF_RG_PATH in compiled mode" is missing from the build.
if [ -f "$(dirname "${BINARY}")/rg" ] 2>/dev/null; then
	kv "extracted rg" "$(dirname "${BINARY}")/rg"
	NOTE "A ripgrep was extracted next to the binary, which means this build lacks the CODEBUFF_RG_PATH patch. That copy is glibc and cannot run."
fi

# --- /proc consistency --------------------------------------------------------
#
# proot-distro binds a hardcoded eight-core /proc/stat over the real one while
# /proc/cpuinfo stays live; systeminformation then throws "Failed to get CPU
# information" and the CLI dies seconds after start (upstream issue 1374). Upstream
# guarded their side, but the skew can return, and this port should not need proot
# at all -- a mismatch here means something else is emulating /proc.

section "proc consistency"
STAT_CPUS="$(grep -c '^cpu[0-9][0-9]* ' /proc/stat 2>/dev/null || echo '?')"
CPUINFO_CPUS="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '?')"
kv "/proc/stat per-cpu lines" "${STAT_CPUS}"
kv "/proc/cpuinfo processors" "${CPUINFO_CPUS}"
kv "nproc" "$(nproc 2>/dev/null || echo '?')"
if [ "${STAT_CPUS}" != "?" ] && [ "${STAT_CPUS}" != "${CPUINFO_CPUS}" ]; then
	NOTE "/proc/stat says ${STAT_CPUS} CPUs, /proc/cpuinfo says ${CPUINFO_CPUS}. If the CLI dies with 'Failed to get CPU information', this is why (upstream issue 1374)."
fi

# --- dependencies and space ----------------------------------------------------

section "dependencies"
have_line git
have_line rg
have_line node
have_line bun

section "disk"
for d in "${PREFIX_DIR}" "${CONFIG_DIR}" "${TMPDIR:-${PREFIX_DIR}/tmp}"; do
	[ -d "${d}" ] || continue
	AVAIL="$(df -Pk "${d}" 2>/dev/null | awk 'NR==2{print $4}')"
	kv "free KB in $(redact "${d}")" "${AVAIL:-?}"
	if [ -n "${AVAIL:-}" ] && [ "${AVAIL}" -lt 51200 ] 2>/dev/null; then
		NOTE "Under 50 MB free in $(redact "${d}"). The CLI unpacks a ~10 MB native library per launch."
	fi
done

# --- exec test ------------------------------------------------------------------

section "exec test"
if [ -x "${BINARY}" ]; then
	OUT="$("${BINARY}" --version 2>&1)"
	RC=$?
	kv "exit code" "${RC}"
	kv "output" "$(printf '%s' "${OUT}" | head -n3 | tr '\n' ' ')"
	if [ "${RC}" -eq 0 ]; then
		printf '\nThe binary starts and exits cleanly. Anything wrong from here on is in the\nTUI, the network or sign-in -- not in the executable.\n'
	else
		case "${OUT}" in
			*"not found"*|*"No such file or directory"*)
				NOTE "exec failed with 'not found'. That is the loader: a glibc or musl binary reports exactly this on Android. Check the 'elf' section above." ;;
			*"GLIBC_"*)
				NOTE "exec failed with a GLIBC_ version error: this is a stock Freebuff release. Install this project's .deb instead." ;;
			*opentui*|*"dlopen"*|*"cannot open shared object"*)
				NOTE "The OpenTUI native library failed to load. This build should use @androidtui/core-android-arm64; report it with this output." ;;
			*"Failed to get CPU information"*)
				NOTE "os.cpus() threw. See the proc consistency section (upstream issue 1374)." ;;
			*"Exec format error"*)
				NOTE "Exec format error: wrong architecture, or the binary is corrupt. Check the 'elf' section." ;;
			*"cannot execute"*)
				NOTE "exec refused. Check SELinux, and that the binary is not on /sdcard." ;;
			*"segmentation"*)
				NOTE "Crashed at startup. If this device uses 16 KiB pages, check the alignment line in the 'elf' section." ;;
		esac
	fi
else
	kv "skipped" "no executable binary"
fi

section "network"
if have curl; then
	CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://codebuff.com/ 2>/dev/null || echo 000)"
	kv "codebuff.com" "HTTP ${CODE}"
	case "${CODE}" in
		000) NOTE "No response from codebuff.com. Freebuff cannot authenticate or reach any model without it." ;;
		2*|3*) : ;;
		*) NOTE "codebuff.com returned HTTP ${CODE}. A captive portal or DNS filter will break sign-in." ;;
	esac
fi

# --- summary ---------------------------------------------------------------------

section "summary"
if [ -z "${PROBLEMS}" ]; then
	printf 'No problems detected.\n'
else
	printf 'Findings:\n%s' "${PROBLEMS}"
	printf '\nIf Freebuff still misbehaves, include this output and the transcript of a\nfailing launch in the issue.\n'
fi
printf '\nReport generated by freebuff-termux diagnose.sh\n'