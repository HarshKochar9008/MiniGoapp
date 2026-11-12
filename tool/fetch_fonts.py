"""Bundles the Google Fonts weights MiniGo uses into assets/google_fonts/.

    pip install fonttools
    python3 tool/fetch_fonts.py

With the files bundled, main.dart turns google_fonts' runtime fetching off:
first launch spends no data on fonts, text never swaps typeface mid-animation,
and it renders where Google's font servers are blocked.

The files are the ones google_fonts would download. Their hashes come from
the google_fonts version in .dart_tool/package_config.json, and every
download is checked against them. google_fonts finds a bundled weight by its
file name, <Family>-<Variant>.ttf, and doesn't hash-check bundled files, so
they can be trimmed:

JetBrains Mono only draws codes, hashes and file paths, so it ships cut down
to Latin and common punctuation (17 KB a weight instead of 109; its coding
ligatures go too). Any other character, say a Cyrillic file name in a path,
falls back to the system font. Outfit draws people's names, so it stays whole.

Using a weight that isn't listed in FONTS? Add it, run this, commit the new
file. test/bundled_fonts_test.dart fails until you do, because a missing
weight doesn't crash: it silently falls back to the system font.
"""
import hashlib
import io
import json
import pathlib
import re
import sys
import urllib.parse
import urllib.request

try:
    from fontTools import subset as fonttools_subset
    from fontTools.ttLib import TTFont
except ImportError:
    sys.exit('needs fontTools: pip install fonttools')

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'assets' / 'google_fonts'

# Basic Latin, Latin-1, dashes / quotes / bullets / ellipsis, arrows, minus.
LATIN = 'U+0020-007E,U+00A0-00FF,U+2010-2027,U+2030-203A,U+2190-2193,U+2212'

# google_fonts method name ->
#   (file name family, OFL folder, weights, characters to keep or None for all)
FONTS = {
    'outfit': ('Outfit', 'outfit', [400, 500, 600], None),
    'jetBrainsMono': ('JetBrainsMono', 'jetbrainsmono', [400, 500, 600], LATIN),
}

VARIANT_NAMES = {
    100: 'Thin', 200: 'ExtraLight', 300: 'Light', 400: 'Regular',
    500: 'Medium', 600: 'SemiBold', 700: 'Bold', 800: 'ExtraBold',
    900: 'Black',
}

LICENSE_URL = 'https://raw.githubusercontent.com/google/fonts/main/ofl/{}/OFL.txt'


def google_fonts_lib():
    config = json.loads((ROOT / '.dart_tool' / 'package_config.json').read_text())
    for package in config['packages']:
        if package['name'] == 'google_fonts':
            root = urllib.parse.urlparse(package['rootUri'])
            path = pathlib.Path(urllib.request.url2pathname(root.path))
            if not path.is_absolute():
                path = (ROOT / '.dart_tool' / path).resolve()
            return path / 'lib'
    sys.exit('google_fonts not found: run `flutter pub get` first')


def font_files(lib, method):
    """{weight: (sha256, length)} for the upright styles of [method]."""
    for part in sorted((lib / 'src' / 'google_fonts_parts').glob('*.dart')):
        source = part.read_text()
        start = source.find(f'static TextStyle {method}(')
        if start < 0:
            continue
        block = source[start:source.find('};', start)]
        return {
            int(weight): (sha, int(length))
            for weight, sha, length in re.findall(
                r"FontWeight\.w(\d+),\s*fontStyle:\s*FontStyle\.normal,\s*\):"
                r"\s*const GoogleFontsFile\(\s*'([0-9a-f]+)',\s*(\d+),",
                block)
        }
    sys.exit(f'GoogleFonts.{method} not found in {lib}')


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read()


def subset(data, unicodes):
    """[data] with only the glyphs for [unicodes], and kerning as its only
    layout feature."""
    options = fonttools_subset.Options()
    options.layout_features = ['kern']
    font = TTFont(io.BytesIO(data))
    subsetter = fonttools_subset.Subsetter(options)
    subsetter.populate(unicodes=fonttools_subset.parse_unicodes(unicodes))
    subsetter.subset(font)
    out = io.BytesIO()
    font.save(out)
    return out.getvalue()


def main():
    lib = google_fonts_lib()
    OUT.mkdir(parents=True, exist_ok=True)
    for method, (family, ofl_dir, weights, keep) in FONTS.items():
        files = font_files(lib, method)
        for weight in weights:
            sha, length = files[weight]
            data = fetch(f'https://fonts.gstatic.com/s/a/{sha}.ttf')
            if len(data) != length or hashlib.sha256(data).hexdigest() != sha:
                sys.exit(f'{family} {weight}: download does not match google_fonts')
            if keep:
                data = subset(data, keep)
            name = f'{family}-{VARIANT_NAMES[weight]}.ttf'
            (OUT / name).write_bytes(data)
            print(f'{name}  {len(data) // 1024} KB')
        (OUT / f'{family}-OFL.txt').write_bytes(fetch(LICENSE_URL.format(ofl_dir)))
        print(f'{family}-OFL.txt')


if __name__ == '__main__':
    main()
