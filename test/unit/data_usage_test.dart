import 'package:ermchat/util/data_usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('windows subtract the snapshot before their start', () async {
    final stats = DataUsageStats.I;
    var clock = DateTime(2026, 1, 10, 12);
    stats
      ..reset()
      ..now = () => clock;

    stats.recordHistory(1000);
    await stats.flush();

    clock = DateTime(2026, 1, 10, 18);
    stats.recordHistory(200);
    await stats.flush();

    clock = DateTime(2026, 1, 12, 18);
    stats.recordHistory(300);
    await stats.flush();

    // A restart keeps the totals but starts the session over.
    stats.reset();
    stats.now = () => clock;
    await stats.load();

    expect(stats.bytesFor(DataSource.history, period: UsagePeriod.all), 1500);
    expect(
      stats.bytesFor(DataSource.history, period: UsagePeriod.session),
      0,
      reason: 'a restart starts the session at zero',
    );
    expect(
      stats.bytesFor(DataSource.history, period: UsagePeriod.day),
      300,
      reason: 'only the usage after the day window starts counts',
    );
    expect(
      stats.bytesFor(DataSource.history, period: UsagePeriod.week),
      1500,
      reason: 'no snapshot before the window means install is younger',
    );

    clock = DateTime(2026, 1, 20, 18);
    stats.recordHistory(700);
    await stats.flush();
    await stats.flush();

    expect(stats.bytesFor(DataSource.history, period: UsagePeriod.day), 700);
    expect(
      stats.bytesFor(DataSource.history, period: UsagePeriod.week),
      700,
      reason: 'the week window starts after the Jan 12 snapshot',
    );
    expect(stats.bytesFor(DataSource.history, period: UsagePeriod.all), 2200);
  });

  test('saved counters follow the period too', () async {
    final stats = DataUsageStats.I;
    var clock = DateTime(2026, 1, 10, 12);
    stats
      ..reset()
      ..now = () => clock;

    stats.recordEmoteList(fromDisk: true);
    await stats.flush();
    expect(
      stats.savedCount(stats.listsFromDisk, period: UsagePeriod.all),
      1,
      reason: 'a flush folds the session into the base exactly once',
    );

    clock = DateTime(2026, 1, 12, 12);
    stats.recordEmoteList(fromDisk: true);
    await stats.flush();

    stats.reset();
    stats.now = () => clock;
    await stats.load();

    expect(
      stats.savedCount(stats.listsFromDisk, period: UsagePeriod.session),
      0,
      reason: 'a restart starts the session at zero',
    );
    expect(stats.savedCount(stats.listsFromDisk, period: UsagePeriod.all), 2);
    expect(
      stats.savedCount(stats.listsFromDisk, period: UsagePeriod.day),
      1,
      reason: 'only the list saved after the day window starts counts',
    );
  });

  test('mobile bytes keep their own window', () async {
    final stats = DataUsageStats.I;
    var clock = DateTime(2026, 2, 1, 9);
    stats
      ..reset()
      ..now = () => clock;

    stats.setMobile(false);
    stats.recordHistory(400);
    clock = DateTime(2026, 2, 1, 10);
    stats.setMobile(true);
    stats.recordHistory(100);
    await stats.flush();

    clock = DateTime(2026, 2, 2, 10);
    stats.setMobile(true);
    stats.recordHistory(50);
    await stats.flush();

    expect(
      stats.bytesFor(
        DataSource.history,
        mobileOnly: true,
        period: UsagePeriod.all,
      ),
      150,
    );
    expect(
      stats.bytesFor(
        DataSource.history,
        mobileOnly: true,
        period: UsagePeriod.day,
      ),
      50,
    );
    expect(stats.bytesFor(DataSource.history, period: UsagePeriod.all), 550);
  });
}
