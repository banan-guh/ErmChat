import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

// Spike A: evidence that flutter_riverpod 3.x fits the app DI/lifecycle needs
// and bridges cleanly to the mutable chat kernel whose leaf state is exposed
// as Flutter ValueNotifiers.

abstract class GreetingService {
  String greet();
}

class RealGreetingService implements GreetingService {
  @override
  String greet() => 'real';
}

class FakeGreetingService implements GreetingService {
  @override
  String greet() => 'fake';
}

class Snapshot {
  const Snapshot({required this.count, required this.other});

  final int count;
  final int other;
}

class SnapshotNotifier extends Notifier<Snapshot> {
  @override
  Snapshot build() => const Snapshot(count: 0, other: 0);

  void bumpCount() =>
      state = Snapshot(count: state.count + 1, other: state.other);
  void bumpOther() =>
      state = Snapshot(count: state.count, other: state.other + 1);
}

class DisposableResource {
  int disposeCount = 0;

  void dispose() => disposeCount++;
}

class TickService extends ChangeNotifier {
  int ticks = 0;

  void tick() {
    ticks++;
    notifyListeners();
  }
}

class IntBox {
  int value = 0;
}

final greetingProvider = Provider<GreetingService>(
  (ref) => RealGreetingService(),
);

final snapshotProvider = NotifierProvider<SnapshotNotifier, Snapshot>(
  SnapshotNotifier.new,
);

final resourceProvider = Provider.autoDispose<DisposableResource>((ref) {
  final resource = DisposableResource();
  ref.onDispose(resource.dispose);
  return resource;
});

// Stand-in for a kernel leaf notifier such as Messages.version.
final versionProvider = Provider<ValueNotifier<int>>((ref) {
  final notifier = ValueNotifier<int>(0);
  ref.onDispose(notifier.dispose);
  return notifier;
});

// Stand-in for a kernel ChangeNotifier observed imperatively.
final tickProvider = ChangeNotifierProvider<TickService>(
  (ref) => TickService(),
);

class _GreetingView extends ConsumerWidget {
  const _GreetingView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Text(ref.watch(greetingProvider).greet());
  }
}

class _SnapshotView extends ConsumerWidget {
  const _SnapshotView({required this.box});

  final IntBox box;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(snapshotProvider);
    box.value++;
    return Text('${snapshot.count}:${snapshot.other}');
  }
}

class _CountView extends ConsumerWidget {
  const _CountView({required this.box});

  final IntBox box;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(snapshotProvider.select((s) => s.count));
    box.value++;
    return Text('count:$count');
  }
}

class _VersionView extends ConsumerWidget {
  const _VersionView({required this.box});

  final IntBox box;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.watch(versionProvider);
    return ValueListenableBuilder<int>(
      valueListenable: notifier,
      builder: (context, value, child) {
        box.value++;
        return Text('v:$value');
      },
    );
  }
}

class _TickListener extends ConsumerStatefulWidget {
  const _TickListener({required this.ticks});

  final List<int> ticks;

  @override
  ConsumerState<_TickListener> createState() => _TickListenerState();
}

class _TickListenerState extends ConsumerState<_TickListener> {
  @override
  Widget build(BuildContext context) {
    ref.listen<TickService>(tickProvider, (previous, next) {
      widget.ticks.add(next.ticks);
    });
    return const SizedBox.shrink();
  }
}

void main() {
  group('ProviderContainer unit tests need no widget binding', () {
    test('service provider override and sharing', () {
      final container = ProviderContainer(
        overrides: [
          greetingProvider.overrideWith((ref) => FakeGreetingService()),
        ],
      );
      addTearDown(container.dispose);

      final a = container.read(greetingProvider);
      final b = container.read(greetingProvider);
      expect(a.greet(), 'fake');
      expect(identical(a, b), isTrue);
    });
  });

  group('override', () {
    test('default provider is shared and real', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(greetingProvider).greet(), 'real');
      expect(
        identical(
          container.read(greetingProvider),
          container.read(greetingProvider),
        ),
        isTrue,
      );
    });

    testWidgets('ProviderScope override swaps in a fake', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            greetingProvider.overrideWithValue(FakeGreetingService()),
          ],
          child: const MaterialApp(home: _GreetingView()),
        ),
      );

      expect(find.text('fake'), findsOneWidget);
    });
  });

  group('watch and select rebuild counts', () {
    testWidgets('watch rebuilds on every state change', (tester) async {
      final box = IntBox();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: _SnapshotView(box: box)),
        ),
      );
      expect(box.value, 1);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(_SnapshotView)),
        listen: false,
      );
      container.read(snapshotProvider.notifier).bumpOther();
      await tester.pump();
      expect(box.value, 2);

      container.read(snapshotProvider.notifier).bumpCount();
      await tester.pump();
      expect(box.value, 3);
    });

    testWidgets('select ignores unrelated field changes', (tester) async {
      final box = IntBox();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: _CountView(box: box)),
        ),
      );
      expect(box.value, 1);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(_CountView)),
        listen: false,
      );
      container.read(snapshotProvider.notifier).bumpOther();
      await tester.pump();
      expect(box.value, 1);

      container.read(snapshotProvider.notifier).bumpCount();
      await tester.pump();
      expect(box.value, 2);
    });
  });

  group('lifecycle', () {
    test('autoDispose disposes once when last listener leaves', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final sub = container.listen(resourceProvider, (previous, next) {});
      final resource = container.read(resourceProvider);
      expect(resource.disposeCount, 0);

      sub.close();
      await container.pump();
      expect(resource.disposeCount, 1);

      container.dispose();
      expect(resource.disposeCount, 1);
    });
  });

  group('kernel bridge', () {
    testWidgets('ValueListenableBuilder drives the rebuild, not Riverpod', (
      tester,
    ) async {
      final box = IntBox();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: _VersionView(box: box)),
        ),
      );
      expect(box.value, 1);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(_VersionView)),
        listen: false,
      );
      final notifier = container.read(versionProvider);

      notifier.value++;
      await tester.pump();
      expect(box.value, 2);

      notifier.value = 5;
      await tester.pump();
      expect(box.value, 3);
    });

    testWidgets('ref.listen observes a ChangeNotifier service', (tester) async {
      final ticks = <int>[];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: _TickListener(ticks: ticks)),
        ),
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(_TickListener)),
        listen: false,
      );
      final service = container.read(tickProvider.notifier);

      service.tick();
      await tester.pump();
      service.tick();
      await tester.pump();

      expect(ticks, [1, 2]);
    });
  });
}
