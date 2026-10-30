import base64
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("generate_appcast", ROOT / "scripts/generate-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sign_tool = ROOT / "build/Sparkle-2.10.1/bin/sign_update"
        if not cls.sign_tool.is_file():
            raise unittest.SkipTest("Run scripts/fetch-sparkle-tools.sh for real Ed25519 checks")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.key = base64.b64encode(os.urandom(32)).decode()

    def generate(self, architecture="arm64"):
        dmg = self.root / f"PiWork-0.1.16-macos-{architecture}.dmg"
        dmg.write_bytes(b"Archive fixture with bytes whose authenticity must be verified.")
        feed = self.root / f"appcast-{architecture}.xml"
        appcast.generate("0.1.16", architecture, dmg, feed, self.sign_tool, self.key,
                         "Fix <unsafe> text & preserve Unicode: 更新")
        return dmg, feed

    def verify(self, path, signature=None, key=None):
        return subprocess.run([str(self.sign_tool), "--ed-key-file", "-", "--verify", str(path)]
                              + ([signature] if signature else []),
                              input=key or self.key, text=True, capture_output=True).returncode == 0

    def test_both_architectures_publish_signed_archives_and_signed_feeds(self):
        for architecture in ["arm64", "x86_64"]:
            dmg, feed = self.generate(architecture)
            item = ET.parse(feed).find("./channel/item")
            enclosure = item.find("enclosure")
            self.assertEqual(item.find(f"{{{appcast.SPARKLE}}}version").text, "0.1.16")
            self.assertEqual(item.find(f"{{{appcast.SPARKLE}}}minimumSystemVersion").text, "13.0.0")
            self.assertEqual(enclosure.attrib["length"], str(dmg.stat().st_size))
            self.assertTrue(enclosure.attrib["url"].endswith(f"/v0.1.16/{dmg.name}"))
            self.assertTrue(self.verify(dmg, enclosure.attrib[f"{{{appcast.SPARKLE}}}edSignature"]))
            self.assertTrue(self.verify(feed))
            self.assertIn("更新", item.find("description").text)

    def test_modified_archive_is_rejected(self):
        dmg, feed = self.generate()
        signature = ET.parse(feed).find("./channel/item/enclosure").attrib[f"{{{appcast.SPARKLE}}}edSignature"]
        dmg.write_bytes(b"Changed archive bytes")
        self.assertFalse(self.verify(dmg, signature))

    def test_modified_feed_is_rejected(self):
        _, feed = self.generate()
        feed.write_bytes(feed.read_bytes().replace(b"13.0.0", b"10.0.0"))
        self.assertFalse(self.verify(feed))

    def test_unrelated_signing_key_is_rejected(self):
        _, feed = self.generate()
        self.assertFalse(self.verify(feed, key=base64.b64encode(os.urandom(32)).decode()))

    def test_mismatched_installer_and_version_are_rejected(self):
        dmg = self.root / "PiWork-0.1.15-macos-arm64.dmg"
        dmg.write_bytes(b"Old archive")
        with self.assertRaises(ValueError):
            appcast.generate("0.1.16", "arm64", dmg, self.root / "feed.xml", self.sign_tool, self.key)

    def test_missing_key_prevents_feed_publication(self):
        result = subprocess.run(["python3", str(ROOT / "scripts/generate-appcast.py"),
                                 "--version", "0.1.16", "--architecture", "arm64",
                                 "--dmg", str(self.root / "missing.dmg"), "--output", str(self.root / "feed.xml"),
                                 "--sign-tool", str(self.sign_tool)],
                                env={key: value for key, value in os.environ.items() if key != "SPARKLE_ED25519_PRIVATE_KEY"},
                                capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "feed.xml").exists())


if __name__ == "__main__":
    unittest.main()
