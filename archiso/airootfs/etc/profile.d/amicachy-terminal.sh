# AmiCachy terminal fallback for minimal installs.
case "${TERM:-}" in
    ""|"xterm-256 color"|"xterm-256_colour"|"unknown")
        export TERM=xterm-256color
        ;;
esac
