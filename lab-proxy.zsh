#!/usr/bin/env zsh
# ProxyCommand for `Host lab` in the `config` next to this file.
#
# ssh runs this instead of connecting itself, so our stdin/stdout *are* the
# connection: nothing here may write to stdout, and every diagnostic goes to
# stderr - which is the user's terminal, for the life of the session.
#
# Besides reaching lab through the build-box bridge, this starts the two
# loopback servers that the `RemoteForward`s in `config` expose there, where
# `tcp-clip-get`/`tcp-clip-set` consume them (see windows/ssh/CLIPBOARD.md in
# the .files repo).  Starting them here is what lets a plain `ssh lab` carry
# the clipboard: the forwards on their own would bind on lab with nothing
# behind them, so a read would come back empty instead of falling back to
# /dev/clipboard, which is indistinguishable from an empty clipboard.

set -eu

transport=(ssh build-box.nix-community.org -- nc -U /home/doronbehar/.ssh-bridge-lab.sock)
get_port=${TCP_CLIP_GET_PORT:-15299}
set_port=${TCP_CLIP_SET_PORT:-15300}

# Unlike a dedicated wrapper, this must never make `ssh lab` itself fail: a
# clipboard that cannot be set up is a warning, and the transport runs anyway.
started=()

cleanup() {
	for pid in $started; do
		# Children that are already gone are expected, so only the probe's
		# stderr is suppressed here - never a failure of the kill itself.
		if kill -0 $pid 2>/dev/null; then
			kill $pid
		fi
	done
}
trap cleanup EXIT INT TERM

listening() {
	# Without `ss` (a minimal environment), skip the check and let socat talk.
	(( $+commands[ss] )) || return 1
	[[ -n $(ss -ltnH "sport = :$1") ]]
}

serve() {
	local port=$1 address=$2
	# Another connection to lab already owns this port.  Leave it running and
	# leave it alone on exit: its forward serves this session too, since the
	# listener lives on lab's loopback, not in any one ssh session.
	if listening $port; then
		return
	fi
	socat -d0 TCP-LISTEN:$port,bind=127.0.0.1,reuseaddr,fork $address >&2 &
	started+=$!
}

# `wl-paste` exits 1 and says "Nothing is copied" on an empty clipboard, which
# is routine and would otherwise surface in the middle of the ssh session;
# hence SYSTEM with the redirect, while socat's own diagnostics stay visible.
serve $get_port 'SYSTEM:"wl-paste --no-newline 2>/dev/null"'
serve $set_port "EXEC:'wl-copy'"

# Give the binds a moment, without holding the connection up for long.
for _ in {1..20}; do
	if listening $get_port && listening $set_port; then
		break
	fi
	sleep 0.05
done
if ! listening $get_port || ! listening $set_port; then
	print -u2 "lab-proxy: clipboard servers did not come up; tcp-clip-* on lab will fall back to /dev/clipboard"
fi

# Deliberately not `exec`: the trap above has to run when the session ends.
$transport
