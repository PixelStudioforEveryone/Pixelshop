from pathlib import Path
import zipfile
import xml.etree.ElementTree as ET

source = Path(r'C:\Users\HQ\Desktop\picture\documents\VIVID调色面板与Compositor_lightcraft对比分析报告.docx')
destination = Path('analysis/render-audit-20261012/kimi-report.txt')
ns = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
with zipfile.ZipFile(source) as package:
    root = ET.fromstring(package.read('word/document.xml'))
lines = []
for paragraph in root.findall('.//w:p', ns):
    text = ''.join(part.text or '' for part in paragraph.findall('.//w:t', ns))
    if text.strip():
        lines.append(text)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text('\n'.join(lines), encoding='utf-8')
print('\n'.join(lines))
