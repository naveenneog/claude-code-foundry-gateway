from rich.cells import cell_len
from rich.segment import Segment
from textual.filter import LineFilter


class AsciiFilter(LineFilter):
    """Transliterate terminal chrome without changing cell geometry."""

    def apply(self, segments, background):
        result = []
        for segment in segments:
            text = []
            for char in segment.text:
                code = ord(char)
                if code < 128:
                    text.append(char)
                elif 0x2500 <= code <= 0x257F:
                    text.append("|" if char in "│┃║╎╏" else "-")
                elif 0x2580 <= code <= 0x259F:
                    text.append("#")
                else:
                    text.append("?" * cell_len(char))
            result.append(Segment("".join(text), segment.style, segment.control))
        return result
