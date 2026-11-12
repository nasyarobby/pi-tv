import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:test/test.dart';

void main() {
  const id = 'dQw4w9WgXcQ';

  group('hosts', () {
    final cases = <String, YouTubeLink>{
      'https://www.youtube.com/watch?v=$id': const YouTubeLink(id),
      'https://youtube.com/watch?v=$id&feature=share': const YouTubeLink(id),
      'http://m.youtube.com/watch?v=$id': const YouTubeLink(id),
      'https://youtu.be/$id': const YouTubeLink(id),
      'https://youtu.be/$id?si=AbCdEf123': const YouTubeLink(id),
      'https://www.youtube.com/shorts/$id': const YouTubeLink(id),
      'https://youtube.com/shorts/$id?feature=share': const YouTubeLink(id),
      'https://www.youtube.com/embed/$id': const YouTubeLink(id),
      'https://www.youtube-nocookie.com/embed/$id?start=12': const YouTubeLink(id, startSeconds: 12),
      'https://music.youtube.com/watch?v=$id&list=RDAMVM$id': const YouTubeLink(id, playlistId: 'RDAMVM$id'),
      'https://www.youtube.com/live/$id': const YouTubeLink(id),
      'www.youtube.com/watch?v=$id': const YouTubeLink(id),
      'youtu.be/$id': const YouTubeLink(id),
      'HTTPS://WWW.YOUTUBE.COM/watch?v=$id': const YouTubeLink(id),
      'https://www.youtube.com/watch?feature=youtu.be&v=$id': const YouTubeLink(id),
    };
    cases.forEach((input, expected) {
      test(input, () => expect(YouTubeLink.parse(input), expected));
    });
  });

  group('timestamps', () {
    test('t seconds', () => expect(YouTubeLink.parse('https://youtu.be/$id?t=42')!.startSeconds, 42));
    test('t with s suffix', () => expect(YouTubeLink.parse('https://youtu.be/$id?t=42s')!.startSeconds, 42));
    test('t=1m30s', () => expect(YouTubeLink.parse('https://www.youtube.com/watch?v=$id&t=1m30s')!.startSeconds, 90));
    test('t=1h2m3s',
        () => expect(YouTubeLink.parse('https://www.youtube.com/watch?v=$id&t=1h2m3s')!.startSeconds, 3723));
    test('t=2m', () => expect(YouTubeLink.parse('https://www.youtube.com/watch?v=$id&t=2m')!.startSeconds, 120));
    test('start=', () => expect(YouTubeLink.parse('https://www.youtube.com/embed/$id?start=75')!.startSeconds, 75));
    test('fragment #t=',
        () => expect(YouTubeLink.parse('https://www.youtube.com/watch?v=$id#t=1m5s')!.startSeconds, 65));
    test('invalid t ignored', () {
      final l = YouTubeLink.parse('https://youtu.be/$id?t=abc')!;
      expect(l.videoId, id);
      expect(l.startSeconds, isNull);
    });
    test('parseTimestamp formats', () {
      expect(YouTubeLink.parseTimestamp('90'), 90);
      expect(YouTubeLink.parseTimestamp('1m30s'), 90);
      expect(YouTubeLink.parseTimestamp('1:30'), 90);
      expect(YouTubeLink.parseTimestamp('1:02:03'), 3723);
      expect(YouTubeLink.parseTimestamp(''), isNull);
      expect(YouTubeLink.parseTimestamp('x'), isNull);
    });
    test('watchUrl carries the start time', () {
      expect(const YouTubeLink(id, startSeconds: 90).watchUrl.toString(), 'https://www.youtube.com/watch?v=$id&t=90s');
      expect(const YouTubeLink(id).watchUrl.toString(), 'https://www.youtube.com/watch?v=$id');
    });
  });

  group('messy share text', () {
    test('title then link', () {
      expect(YouTubeLink.parse('Rick Astley - Never Gonna Give You Up https://youtu.be/$id?si=xyz'),
          const YouTubeLink(id));
    });
    test('link on its own line with trailing punctuation', () {
      expect(YouTubeLink.parse('Watch this!\nhttps://www.youtube.com/watch?v=$id&t=1m30s.\nSo good'),
          const YouTubeLink(id, startSeconds: 90));
    });
    test('link in parentheses', () {
      expect(YouTubeLink.parse('(see https://youtu.be/$id)'), const YouTubeLink(id));
    });
    test('skips other URLs before the YouTube one', () {
      expect(YouTubeLink.parse('https://example.com/x and https://m.youtube.com/watch?v=$id'), const YouTubeLink(id));
    });
    test('Android share format with quotes', () {
      expect(YouTubeLink.parse('"Song" on YouTube: "https://music.youtube.com/watch?v=$id&si=abc"'),
          const YouTubeLink(id));
    });
  });

  group('playlists', () {
    const list = 'PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf';
    test('watch?v= plus list keeps the list and index', () {
      final l = YouTubeLink.parse('https://www.youtube.com/watch?v=$id&list=$list&index=3&t=10s')!;
      expect(l, const YouTubeLink(id, playlistId: list, playlistIndex: 3, startSeconds: 10));
      expect(l.isPlaylist, isTrue);
      expect(l.watchUrl.toString(), 'https://www.youtube.com/watch?v=$id&list=$list&index=3&t=10s');
    });
    test('playlist?list= is a playlist-only link opened as the playlist URL', () {
      final l = YouTubeLink.parse('https://www.youtube.com/playlist?list=$list')!;
      expect(l, const YouTubeLink.playlist(list));
      expect(l.videoId, isNull);
      expect(l.thumbnailUrl, isNull);
      expect(l.watchUrl.toString(), 'https://www.youtube.com/playlist?list=$list');
    });
    test('the TV URL is never rewritten as a bare watch?v= link', () {
      for (final input in [
        'https://youtu.be/$id?list=$list',
        'https://m.youtube.com/watch?v=$id&list=$list',
        'https://music.youtube.com/watch?v=$id&list=$list',
        'https://www.youtube.com/embed/$id?list=$list',
      ]) {
        final u = YouTubeLink.parse(input)!.watchUrl;
        expect(u.queryParameters['list'], list, reason: input);
        expect(u.queryParameters['v'], id, reason: input);
      }
    });
    test('music.youtube.com playlist, embed/videoseries and watch?list=', () {
      expect(YouTubeLink.parse('https://music.youtube.com/playlist?list=$list'), const YouTubeLink.playlist(list));
      expect(
          YouTubeLink.parse('https://www.youtube.com/embed/videoseries?list=$list'), const YouTubeLink.playlist(list));
      expect(YouTubeLink.parse('https://www.youtube.com/watch?list=$list&index=2'),
          const YouTubeLink.playlist(list, playlistIndex: 2));
    });
    test('playlist share text', () {
      expect(YouTubeLink.parse('My mix 🎶 https://youtube.com/playlist?list=$list&si=abc.'),
          const YouTubeLink.playlist(list));
    });
    test('index without a list is ignored; bad index ignored', () {
      expect(YouTubeLink.parse('https://www.youtube.com/watch?v=$id&index=4'), const YouTubeLink(id));
      expect(YouTubeLink.parse('https://www.youtube.com/watch?v=$id&list=$list&index=x'),
          const YouTubeLink(id, playlistId: list));
    });
    test('json and label', () {
      const l = YouTubeLink(id, playlistId: list, playlistIndex: 2);
      expect(l.toJson(), {'videoId': id, 'playlistId': list, 'playlistIndex': 2});
      expect(l.shortLabel, contains('playlist $list'));
    });
  });

  group('rejection', () {
    for (final bad in [
      '',
      'hello world',
      'https://example.com/watch?v=$id',
      'https://youtube.com.evil.com/watch?v=$id',
      'https://evilyoutube.com/watch?v=$id',
      'https://vimeo.com/123456',
      'https://www.youtube.com/watch?v=short',
      'https://www.youtube.com/playlist?list=',
      'https://www.youtube.com/playlist?list=bad%20id',
      'https://www.youtube.com/@channel?list=PLabc',
      'https://example.com/playlist?list=PLabcdef',
      'https://www.youtube.com/@channel',
      'ftp://youtube.com/watch?v=$id',
      'javascript:alert(1)//youtu.be/$id',
      'https://youtu.be/',
    ]) {
      test('rejects "$bad"', () => expect(YouTubeLink.parse(bad), isNull));
    }
    test('parseOrThrow throws', () {
      expect(() => YouTubeLink.parseOrThrow('https://example.com'), throwsFormatException);
    });
  });
}
