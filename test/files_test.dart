import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/screens/files_screen.dart';

void main() {
  test('classifies by extension, defaulting to text', () {
    expect(previewKind('shot.PNG'), PreviewKind.image);
    expect(previewKind('notes.md'), PreviewKind.markdown);
    expect(previewKind('notes.markdown'), PreviewKind.markdown);
    expect(previewKind('notes.txt'), PreviewKind.text);
    expect(previewKind('Makefile'), PreviewKind.text);
    expect(previewKind('.bashrc'), PreviewKind.text);
    expect(previewKind('app.apk'), PreviewKind.binary);
  });

  test('caps keep a big file off the phone', () {
    expect(capFor(PreviewKind.text), lessThan(imageCap));
    expect(capFor(PreviewKind.image), imageCap);
  });

  test('paths', () {
    expect(joinPath('/home/u', 'a.md'), '/home/u/a.md');
    expect(joinPath('/', 'a.md'), '/a.md');
    expect(parentOf('/home/u/a.md'), '/home/u');
    expect(parentOf('/home'), '/');
    expect(baseName('/home/u/a.md'), 'a.md');
    expect(baseName('/'), '/');
  });

  test('sizes', () {
    expect(humanSize(512), '512 B');
    expect(humanSize(4300000), '4.1 MB');
  });

  test('hidden entries are filtered unless asked for', () {
    SftpName n(String f) =>
        SftpName(filename: f, longname: f, attr: SftpFileAttrs());
    final all = [n('.git'), n('lib'), n('.env'), n('README.md')];
    expect(visible(all, false).map((e) => e.filename), ['lib', 'README.md']);
    expect(visible(all, true).length, 4);
  });

  test('the picker offers directories only', () {
    SftpName n(String f, {bool dir = false}) => SftpName(
        filename: f,
        longname: f,
        attr: SftpFileAttrs(
            mode: SftpFileMode.value(dir ? 0x4000 : 0x8000)));
    final all = [n('lib', dir: true), n('README.md')];
    expect(visible(all, false, dirsOnly: true).map((e) => e.filename), ['lib']);
  });
}
