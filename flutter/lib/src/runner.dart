// The relay loop: verify an envelope, check every URL against the allowlist,
// run each instruction on the platform's Host, and return the results.
// Mirrors packages/core/src/runner.ts.

import 'allowlist.dart';
import 'guard.dart';
import 'host.dart';
import 'protocol.dart';
import 'verify.dart';

/// Fetch instructions per store per minute (PROTOCOL.md "Rate caps").
const int fetchPerMinute = 120;

/// The last instruction of a job.
sealed class Terminal {
  const Terminal();
}

class TerminalDone extends Terminal {
  const TerminalDone(this.result);
  final Object? result;
}

class TerminalFail extends Terminal {
  const TerminalFail(this.code, this.message);
  final String code;
  final String message;
}

/// What one envelope produced.
class StepOutcome {
  const StepOutcome({required this.payload, required this.results, required this.terminal});
  final InstructionsPayload payload;
  final List<InstructionResult> results;
  final Terminal? terminal;
}

int _now() => DateTime.now().millisecondsSinceEpoch;

String _short(Object e) {
  final s = e.toString();
  return s.length > 120 ? s.substring(0, 120) : s;
}

class Runner {
  Runner(this._host, {Allowlist? allowlist, Map<String, String>? keys})
      : allowlist = allowlist ?? Allowlist(),
        _keys = keys;

  final MealioHost _host;
  final Allowlist allowlist;
  final Map<String, String>? _keys;
  final Map<String, List<int>> _fetchStamps = <String, List<int>>{};

  /// Verify and run one envelope. Throws [EnvelopeError] when it must be refused.
  ///
  /// `onStep` is called before each instruction that actually runs (not for
  /// skipped ones, nor for `done`/`fail`). An exception it throws is ignored:
  /// a progress callback never breaks a run.
  Future<StepOutcome> run(Envelope env, String? job, int lastSeq, {void Function(Instruction ins)? onStep}) async {
    final payload = checkInstructions(await openEnvelope(env, _keys), job, lastSeq);
    final results = <InstructionResult>[];
    Terminal? terminal;
    var failed = false;

    for (final Instruction ins in payload.instructions) {
      // done / fail end the job even after a failure, as in the reference.
      if (ins is DoneOp) {
        terminal = TerminalDone(ins.result);
        break;
      }
      if (ins is FailOp) {
        terminal = TerminalFail(ins.code, ins.message);
        break;
      }
      if (failed) {
        results.add(_skipped(ins));
        continue;
      }
      try {
        onStep?.call(ins);
      } catch (_) {
        // A progress callback never breaks a run.
      }
      final r = await _one(payload.store, ins);
      results.add(r);
      if (!r.ok) failed = true;
    }
    return StepOutcome(payload: payload, results: results, terminal: terminal);
  }

  Future<InstructionResult> _one(String store, Instruction ins) async {
    final t0 = _now();
    switch (ins) {
      case final PageOpen i: {
        final v = allowlist.check(store, i.url, UrlUse.page);
        if (!v.ok) return PageOpenResult(id: i.id, ok: false, error: 'blocked', ms: 0);
        try {
          final r = await _host.openPage(store, i.url, i.timeoutMs);
          return PageOpenResult(id: i.id, ok: r.ok, finalUrl: r.finalUrl, error: r.error, ms: _now() - t0);
        } catch (_) {
          return PageOpenResult(id: i.id, ok: false, error: 'load_failed', ms: _now() - t0);
        }
      }
      case final PageScript i: {
        try {
          final r = await _host.runScript(store, guardScript, i.script, i.until, i.timeoutMs);
          return PageScriptResult(
            id: i.id,
            ok: r.error == null || r.error!.isEmpty,
            messages: r.messages,
            timedOut: r.timedOut,
            error: r.error,
            ms: _now() - t0,
          );
        } catch (e) {
          return PageScriptResult(
            id: i.id,
            ok: false,
            messages: const <JsonMessage>[],
            timedOut: false,
            error: _short(e),
            ms: _now() - t0,
          );
        }
      }
      case final ShowLogin i: {
        final v = allowlist.check(store, i.url, UrlUse.login);
        if (!v.ok) {
          return ShowLoginResult(
            id: i.id,
            ok: false,
            outcome: LoginOutcome.cancelled,
            messages: const <JsonMessage>[],
            error: 'blocked',
            ms: 0,
          );
        }
        try {
          final r = await _host.showLogin(LoginRequest(
            store: store,
            url: i.url,
            title: i.title,
            guard: guardScript,
            check: i.check,
            doneWhen: i.doneWhen,
            doneWhenUrl: i.doneWhenUrl,
            timeoutMs: i.timeoutMs,
            allowNavigation: (String u) => allowlist.check(store, u, UrlUse.login).ok,
          ));
          return ShowLoginResult(id: i.id, ok: true, outcome: r.outcome, messages: r.messages, ms: _now() - t0);
        } catch (e) {
          return ShowLoginResult(
            id: i.id,
            ok: false,
            outcome: LoginOutcome.cancelled,
            messages: const <JsonMessage>[],
            error: _short(e),
            ms: _now() - t0,
          );
        }
      }
      case final FetchOp i: {
        final v = allowlist.check(store, i.request.url, UrlUse.fetch);
        if (!v.ok) return FetchResult(id: i.id, ok: false, error: 'blocked', ms: 0);
        if (_overRate(store)) return FetchResult(id: i.id, ok: false, error: 'rate', ms: 0);
        try {
          final r = await _host.fetch(store, i.request, i.timeoutMs, i.maxBytes);
          return FetchResult(
            id: i.id,
            ok: r.ok,
            status: r.status,
            headers: r.headers,
            body: r.body,
            truncated: r.truncated,
            error: r.error,
            ms: _now() - t0,
          );
        } catch (_) {
          return FetchResult(id: i.id, ok: false, error: 'no_response', ms: _now() - t0);
        }
      }
      case DoneOp():
      case FailOp():
        // run() handles these before calling _one.
        throw const EnvelopeError('unsupported_op');
    }
  }

  bool _overRate(String store) {
    final t = _now();
    final list = _fetchStamps.putIfAbsent(store, () => <int>[]);
    while (list.isNotEmpty && t - list.first > 60000) {
      list.removeAt(0);
    }
    if (list.length >= fetchPerMinute) return true;
    list.add(t);
    return false;
  }
}

InstructionResult _skipped(Instruction ins) {
  switch (ins) {
    case PageScript():
      return PageScriptResult(
        id: ins.id,
        ok: false,
        messages: const <JsonMessage>[],
        timedOut: false,
        skipped: true,
        ms: 0,
      );
    case ShowLogin():
      return ShowLoginResult(
        id: ins.id,
        ok: false,
        outcome: LoginOutcome.cancelled,
        messages: const <JsonMessage>[],
        skipped: true,
        ms: 0,
      );
    case FetchOp():
      return FetchResult(id: ins.id, ok: false, skipped: true, ms: 0);
    case PageOpen():
    case DoneOp():
    case FailOp():
      return PageOpenResult(id: ins.id, ok: false, skipped: true, ms: 0);
  }
}
