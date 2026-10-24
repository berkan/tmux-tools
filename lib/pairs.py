# The pairs of brackets and quotes the tools share, from the @tmux-tools-pairs
# option, two characters each: electric-pair types them in pairs, dabbrev
# closes a completion after an opener and puts LEFT |( between one,
# expand-region takes the brackets among them (the pairs of two different
# characters) as regions.

OPTION, DEFAULT = '@tmux-tools-pairs', '()[]{}""' "''" '``'


def pairs(tmux):
    """{opener: closer} from OPTION, read with TMUX (a tool's tmux(*args));
    DEFAULT when it is unset (not when '')."""
    text = tmux('show-options', '-gqv', OPTION).rstrip('\n')
    if text == '' and not tmux('show-options', '-gq', OPTION):
        text = DEFAULT
    return {text[i]: text[i + 1] for i in range(0, len(text) - 1, 2)}
