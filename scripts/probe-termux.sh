#!/data/data/com.termux/files/usr/bin/bash
#
# Freebuff for Termux — on-device prerequisite probe.
#
# This tests the two things this port cannot build itself: someone else's Bionic
# Bun runtime, and someone else's Bionic libopentui.so. Both are prebuilt .deb /
# npm artifacts, so the whole foundation can be validated on a phone in a couple
# of minutes -- long before committing to a full Freebuff build.
#
# It deliberately does NOT build or run Freebuff. If this passes, the port's
# foundation is sound and what remains is a packaging exercise; if it fails, the
# output says which of the two upstream artifacts is at fault.
#
# Usage:
#   ./probe-termux.sh              run every check
#   ./probe-termux.sh --quick      skip the OpenTUI load test (needs npm)
#   ./probe-termux.sh --no-install do not install anything, just report
#
# Output is plain text. Paste it into an issue.
#
#   License: Apache-2.0.

set -u

QUICK=0
NO_INSTALL=0
for arg in "$@"; do
	case "${arg}" in
		--quick)      QUICK=1 ;;
		--no-install) NO_INSTALL=1 ;;
		-h|--help)    sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) printf 'probe: unknown argument: %s\n' "${arg}" >&2; exit 2 ;;
	esac
done

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BUN_VERSION="1.4.2-patched"
BUN_DEB="bun_${BUN_VERSION}_aarch64.deb"
BUN_URL="https://github.com/bd-loser/bun-termux/releases/download/v${BUN_VERSION}/${BUN_DEB}"
OTUI_VERSION="0.5.14"

PROBLEMS=""
FAILURES=0
NOTE() { PROBLEMS="${PROBLEMS}  - $1"$'\n'; }
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n== %s ==\n' "$1"; }
kv() { printf '%-26s %s\n' "$1" "$2"; }
ok() { printf '  [ok]   %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; FAILURES=$(( FAILURES + 1 )); }

# --- device ------------------------------------------------------------------

section "device"
kv "architecture" "$(uname -m)"
kv "kernel" "$(uname -r)"
kv "PREFIX" "$PREFIX"
if have getprop; then
	kv "android" "$(getprop ro.build.version.release 2>/dev/null || echo '?')"
	kv "android sdk" "$(getprop ro.build.version.sdk 2>/dev/null || echo '?')"
	kv "device" "$(getprop ro.product.model 2>/dev/null || echo '?')"
else
	kv "android" "getprop unavailable -- this does not look like Termux"
	bad "not running inside Termux"
fi

if [ "$(uname -m)" != "aarch64" ]; then
	bad "this port is aarch64-only; there is no 32-bit Android build of Bun or OpenTUI"
fi

PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo '?')"
kv "page size" "${PAGE_SIZE}"
if [ "${PAGE_SIZE}" = "16384" ]; then
	printf '  note: 16 KiB pages. Both upstream artifacts below are built for this,\n'
	printf '        and the .so is checked for segment alignment.\n'
fi

# Disk and RAM, because the later build needs both.
kv "free disk" "$(df -Ph "$PREFIX" 2>/dev/null | awk 'NR==2{print $4}')"
kv "free RAM" "$(free -h 2>/dev/null | awk '/^Mem:/{print $7}')"

# --- prerequisite 1: Bionic Bun ----------------------------------------------

section "prerequisite 1/2: Bionic Bun (bun-termux)"

kv "wanted version" "${BUN_VERSION}-patched"
if have bun; then
	kv "bun on PATH" "$(command -v bun)"
	kv "bun --version" "$(bun --version 2>&1 | head -n1)"
else
	kv "bun on PATH" "not installed"
fi

if [ "${NO_INSTALL}" -eq 1 ]; then
	printf '  (--no-install: not changing anything)\n'
elif ! have bun; then
	printf '  installing from %s\n' "$BUN_URL"
	if command -v curl >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
		curl -fsSL -o "$PREFIX/tmp/${BUN_DEB}" "$BUN_URL" &&
			dpkg -i "$PREFIX/tmp/${BUN_DEB}" >/dev/null 2>&1 &&
			rm -f "$PREFIX/tmp/${BUN_DEB}" &&
			ok "installed" || bad "could not install the .deb (needs dpkg and network)"
	else
		printf '  (curl or dpkg missing -- run: pkg install curl dpkg)\n'
	fi
fi

if have bun; then
	BUN="$(command -v bun)"
	kv "resolved bun" "$BUN"

	VERSION="$(bun --version 2>&1 | head -n1)"
	case "${VERSION}" in
		"${BUN_VERSION%-patched}"*) ok "version ${VERSION} matches the pinned build" ;;
		*) bad "bun ${VERSION}, expected ${BUN_VERSION%-patched*} (Termux's stock bun will not work: it has no FFI launcher)" ;;
	esac

	# The critical distinction: FFI needs the launcher script, not the raw ELF.
	BUN_FILE="$(file -b "$BUN" 2>/dev/null || echo 'unknown (pkg install file)')"
	kv "what is on PATH" "${BUN_FILE}"
	case "${BUN_FILE}" in
		*ELF*)
			bad "this is a raw ELF, not the patched launcher. OpenTUI's FFI crashes under it, so the build would fail confusingly later. Termux's own bun package is not a substitute." ;;
		*)
			ok "launcher script, not a raw ELF -- FFI should work" ;;
	esac

	# Does the runtime actually report Android? The OpenTUI redirect keys off it.
	PLATFORM="$(bun -e 'console.log(process.platform + "-" + process.arch)' 2>&1 | tail -n1)"
	kv "process.platform" "${PLATFORM}"
	case "${PLATFORM}" in
		android-*) ok "reports android; the build script maps this to the android-arm64 target" ;;
		linux-*)   printf '  note: reports linux rather than android. The OpenTUI redirect keys off\n        process.platform, so if this stays "linux" the build will stage the\n        glibc libopentui.so instead of the Android one.\n' ;;
		*)         bad "unexpected platform '${PLATFORM}'" ;;
	esac

	# FFI itself, which is what OpenTUI is loaded through.
	if printf 'const f = Bun.dlopen ? "yes" : "no"; console.log(f);\n' > "$PREFIX/tmp/probe-ffi.ts"; then
		if ( cd "$PREFIX/tmp" && bun -e 'console.log(typeof Bun.dlopen)' ) >/dev/null 2>&1; then
			ok "Bun.dlopen is available -- FFI path is present"
		else
			bad "Bun.dlopen is unavailable; this runtime cannot load OpenTUI's native module"
		fi
		rm -f "$PREFIX/tmp/probe-ffi.ts"
	fi
fi

# --- prerequisite 2: Bionic libopentui.so ------------------------------------

section "prerequisite 2/2: Bionic libopentui.so (@androidtui)"

kv "wanted version" "${OTUI_VERSION}"
if [ "${QUICK}" -eq 1 ]; then
	printf '  (--quick: skipping)\n'
elif ! have npm; then
	printf '  npm is not installed, so the module cannot be fetched. Install it with:\n'
	printf '    pkg install nodejs\n'
	printf '  then re-run without --quick.\n'
else
	PROBE_DIR="$PREFIX/tmp/freebuff-probe"
	rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
	cd "$PROBE_DIR" || exit 1
	printf '{"name":"freebuff-probe","private":true}\n' > package.json

	printf '  fetching @androidtui/core-android-arm64@%s ...\n' "$OTUI_VERSION"
	if npm install --silent --no-audit --no-fund \
		"@androidtui/core-android-arm64@${OTUI_VERSION}" >/dev/null 2>&1; then
		SO="$(find node_modules -name 'libopentui.so' | head -n1)"
		if [ -z "$SO" ]; then
			bad "the package installed but contains no libopentui.so"
		else
			ok "found $(printf '%s' "$SO" | sed 's|.*node_modules/||')"
			kv "size" "$(wc -c < "$SO" | tr -d ' ') bytes"

			SO_FILE="$(file -b "$SO" 2>/dev/null || echo 'unknown')"
			kv "file" "$SO_FILE"
			case "${SO_FILE}" in
				*aarch64*|*ARM\ aarch64*) ok "AArch64" ;;
				*) bad "not an AArch64 shared object: ${SO_FILE}" ;;
			esac

			if have readelf; then
				NEEDED="$(readelf -dW "$SO" 2>/dev/null | awk '/NEEDED/{print $NF}' | tr '\n' ' ')"
				kv "NEEDED" "${NEEDED:-none}"
				case "${NEEDED}" in
					*libc.so*) ok "links Bionic libc" ;;
					*libc.so.6*|*ld-linux*|*libc.musl*)
						bad "links a glibc/musl libc; Android's linker will refuse this .so" ;;
					"")
						printf '  note: no NEEDED entries. Fine if it is statically self-contained.\n' ;;
				esac

				if [ "${PAGE_SIZE}" = "16384" ]; then
					MIS=0
					for a in $(readelf -lW "$SO" 2>/dev/null | awk '$1 == "LOAD" { print $NF }'); do
						a="${a%]}"
						v=$(( a )) 2>/dev/null || continue
						[ $(( v % 16384 )) -ne 0 ] && MIS=$(( MIS + 1 ))
					done
					if [ "$MIS" -gt 0 ]; then
						bad "${MIS} PT_LOAD segment(s) not 16 KiB aligned; unusable on this device"
					else
						ok "16 KiB aligned"
					fi
				fi
			else
				printf '  (readelf missing -- pkg install binutils -- skipping the libc check)\n'
			fi

			# The real test: let OpenTUI's own resolver find it.
			if npm install --silent --no-audit --no-fund \
				"@androidtui/core@${OTUI_VERSION}" >/dev/null 2>&1 && have bun; then
				printf '  loading @androidtui/core through Bun FFI ...\n'
				cat > load.ts <<'EOF'
// Force the module's top-level await to run its native resolver.
await import('@androidtui/core')
console.log('OPENTUI_LOADED')
EOF
				OUT="$(cd "$PROBE_DIR" && bun run load.ts 2>&1)"
				case "${OUT}" in
					*OPENTUI_LOADED*) ok "@androidtui/core loaded and dlopen'd its native module" ;;
					*)
						bad "@androidtui/core failed to load:"
						printf '%s\n' "$OUT" | head -n 20 | sed 's/^/         /'
						;;
				esac
			else
				printf '  (could not install @androidtui/core; skipping the load test)\n'
			fi
		fi
	else
		bad "npm install of @androidtui/core-android-arm64 failed. Check network and npm version."
	fi
	cd "$PREFIX" || true
fi

# --- environment notes -------------------------------------------------------

section "environment"
kv "TERM" "${TERM:-<unset>}"
case "${TERM:-}" in
	xterm-256color|alacritty|kitty|foot|wezterm|ghostty|tmux-256color|screen*|xterm*) : ;;
	*) printf '  note: TERM=%s. The TUI reads it for capabilities; xterm-256color is the safe choice.\n' "${TERM:-unset}" ;;
esac
for tool in git rg dpkg node; do
	if have "$tool"; then kv "$tool" "$(command -v "$tool")"; else kv "$tool" "MISSING (pkg install $tool)"; fi
done

# --- summary -----------------------------------------------------------------

section "summary"
if [ "$FAILURES" -eq 0 ]; then
	printf 'Both upstream prerequisites are present and loadable.\n\n'
	printf 'That is the part this port could not verify without hardware. The remaining\n'
	printf 'work is building Freebuff itself against them:\n\n'
	printf '  ./ci/build-on-device.sh\n\n'
	printf 'Expect it to take a long time and a lot of RAM -- Freebuff is a large\n'
	printf 'monorepo. A desktop or CI build via ci/build-on-runner.sh is much faster.\n'
else
	printf '%s check(s) failed:\n%s' "$FAILURES" "$PROBLEMS"
	printf '\nSend this output. It isolates the failure to one of the two upstream\n'
	printf 'artifacts, which is exactly the information needed to decide what to do.\n'
fi
printf '\nGenerated by freebuff-termux probe-termux.sh\n'