// Round 7 (spec-0.6-round7.md), the in-page guard port: the shipped guard is
// the TypeScript one with its round 7 form, worker and XHR changes.
import 'package:flutter_test/flutter_test.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

void main() {
  test('the guard judges a submit in shadow roots, without a second FormData', () {
    // At window and each shadow root, skipped when already prevented (round 8: capture phase).
    expect(guardScript, contains("addEL(t, 'submit', onSubmit, true)"));
    expect(guardScript, contains('evPrevented'));
    expect(guardScript, contains('attachShadow'));
    expect(guardScript, isNot(contains("w.addEventListener('submit', function (e) {")));
    // Fields read from the controls: the page's formdata listener fires once.
    expect(guardScript, isNot(contains('new FD(form)')));
    // Worker subclasses keep their prototype; sync XHR with a Blob is sent at once.
    expect(guardScript, contains('construct(W, args, NT)'));
    expect(guardScript, contains('if (sync) return go(null);'));
  });
}
