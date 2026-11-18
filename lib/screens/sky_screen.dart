import 'package:flutter/material.dart';

import '../ui/tokens.dart';

import '../astro/astronomy.dart';
import '../astro/night_report.dart';
import '../sky/location_service.dart';
import '../sky/weather_service.dart';
import '../widgets/sky_painters.dart';

/// Sky conditions: twilight, moon and cloud forecast for the next 3 nights.
/// The astronomy works offline; only the cloud forecast needs the internet.
class SkyScreen extends StatefulWidget {
  const SkyScreen({super.key});

  @override
  State<SkyScreen> createState() => _SkyScreenState();
}

class _SkyScreenState extends State<SkyScreen> {
  final _locations = LocationService();
  final _weather = WeatherService();

  SkyLocation? _location;
  String? _locationError;
  bool _locating = false;

  WeatherForecast? _forecast;
  String? _forecastError;
  bool _loadingForecast = false;

  int _night = 0;
  NightReport? _report;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final saved = await _locations.saved();
    if (!mounted) return;
    if (saved != null) {
      _setLocation(saved);
    } else {
      await _useGps();
    }
  }

  Future<void> _useGps() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      _setLocation(await _locations.current());
    } on LocationFailure catch (e) {
      if (mounted) setState(() => _locationError = e.message);
    } catch (e) {
      if (mounted) setState(() => _locationError = 'Location failed: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _setLocation(SkyLocation loc) {
    setState(() {
      _location = loc;
      _forecast = null;
      _forecastError = null;
    });
    _rebuildReport();
    _loadForecast();
  }

  Future<void> _loadForecast({bool force = false}) async {
    final loc = _location;
    if (loc == null) return;
    setState(() {
      _loadingForecast = true;
      _forecastError = null;
    });
    try {
      final f = await _weather.fetch(loc.lat, loc.lon, force: force);
      if (!mounted || _location != loc) return;
      _forecast = f;
    } catch (e) {
      if (mounted) _forecastError = 'Cloud forecast unavailable. Are you offline?';
    } finally {
      if (mounted) {
        setState(() => _loadingForecast = false);
        _rebuildReport();
      }
    }
  }

  /// Local noon of the evening that starts night [index] (0 = tonight).
  /// Before noon, "tonight" still means the night that is ending/ongoing.
  DateTime _windowStart(int index) {
    final now = DateTime.now();
    final base = now.hour < 12 ? now.subtract(const Duration(days: 1)) : now;
    return DateTime(base.year, base.month, base.day + index, 12);
  }

  void _rebuildReport() {
    final loc = _location;
    if (loc == null) return;
    setState(() {
      _report = NightReport.build(
        lat: loc.lat,
        lon: loc.lon,
        windowStart: _windowStart(_night),
        forecast: _forecast,
      );
    });
  }

  Future<void> _editLocation() async {
    final latCtrl = TextEditingController(text: _location?.lat.toStringAsFixed(4) ?? '');
    final lonCtrl = TextEditingController(text: _location?.lon.toStringAsFixed(4) ?? '');
    final result = await showDialog<SkyLocation>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Shooting location'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: latCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Latitude (−90 to 90, N positive)'),
            ),
            TextField(
              controller: lonCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Longitude (−180 to 180, E positive)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final lat = double.tryParse(latCtrl.text.replaceAll(',', '.'));
              final lon = double.tryParse(lonCtrl.text.replaceAll(',', '.'));
              if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) return;
              Navigator.pop(c, SkyLocation(lat: lat, lon: lon, fromGps: false));
            },
            child: const Text('Use'),
          ),
        ],
      ),
    );
    latCtrl.dispose();
    lonCtrl.dispose();
    if (result != null) {
      await _locations.save(result);
      _setLocation(result);
    }
  }

  // ------------------------------------------------------------ formatting

  static String _time(DateTime? t) {
    if (t == null) return '—';
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String _date(DateTime t) {
    final l = t.toLocal();
    return '${_weekdays[l.weekday - 1]} ${l.day} ${_months[l.month - 1]}';
  }

  static String _dur(Duration d) => '${d.inHours}h ${d.inMinutes.remainder(60).toString().padLeft(2, '0')}m';

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sky conditions'),
        actions: [
          IconButton(
            tooltip: 'Refresh forecast',
            onPressed: _location == null || _loadingForecast ? null : () => _loadForecast(force: true),
            icon: _loadingForecast
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          _locationRow(),
          if (_location != null) ...[
            const SizedBox(height: 8),
            _nightPicker(),
          ],
          if (report != null) ...[
            const SizedBox(height: 12),
            _summaryCard(report),
            const SizedBox(height: 12),
            _twilightCard(report),
            const SizedBox(height: 12),
            _moonCard(report),
            const SizedBox(height: 12),
            _milkyWayCard(report),
            const SizedBox(height: 12),
            _cloudCard(report),
            const SizedBox(height: 16),
            const Text(
              'Times are in this phone\'s time zone. Weather data by Open-Meteo.com (CC BY 4.0).',
              style: TextStyle(fontSize: 11, color: V.textFaint),
            ),
          ],
        ],
      ),
    );
  }

  Widget _locationRow() {
    final loc = _location;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(loc?.fromGps == true ? Icons.my_location : Icons.place_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    loc == null ? (_locating ? 'Finding your location…' : 'No location yet') : loc.label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Use my location',
                  onPressed: _locating ? null : _useGps,
                  icon: _locating
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.gps_fixed),
                ),
                IconButton(tooltip: 'Enter coordinates', onPressed: _editLocation, icon: const Icon(Icons.edit_location_alt_outlined)),
              ],
            ),
            if (_locationError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(_locationError!, style: const TextStyle(color: V.amber, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _nightPicker() {
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        for (var i = 0; i < 3; i++)
          ButtonSegment(
            value: i,
            label: Text(i == 0 ? 'Tonight' : i == 1 ? 'Tomorrow' : _date(_windowStart(i)).split(' ').first),
          ),
      ],
      selected: {_night},
      onSelectionChanged: (s) {
        _night = s.first;
        _rebuildReport();
      },
    );
  }

  Widget _card({required String title, IconData? icon, required List<Widget> children}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 18, color: V.ion), const SizedBox(width: 8)],
              Flexible(
                child: Text(title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(NightReport r) {
    final best = r.bestWindow;
    return _card(
      title: 'Night of ${_date(r.windowStart)}',
      icon: Icons.auto_awesome,
      children: [
        Text(r.summary, style: const TextStyle(fontSize: 16)),
        if (best != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${_time(best.start)} – ${_time(best.end)}',
                style: V.readout(26, color: V.ion)),
          ),
        const SizedBox(height: 8),
        _kv('Full darkness', r.darkRanges.isEmpty ? 'none' : _dur(r.darkDuration)),
        _kv('Dark and moon down', r.moonFreeDarkRanges.isEmpty
            ? 'none'
            : r.moonFreeDarkRanges.map((x) => '${_time(x.start)}–${_time(x.end)}').join(', ')),
        if (r.dewRisk)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Row(children: [
              Icon(Icons.water_drop_outlined, size: 16, color: V.amber),
              SizedBox(width: 6),
              Expanded(
                child: Text('Dew likely: the lens may fog. Use a lens heater or hand warmer.',
                    style: TextStyle(color: V.amber, fontSize: 13)),
              ),
            ]),
          ),
      ],
    );
  }

  Widget _twilightCard(NightReport r) {
    return _card(
      title: 'Twilight',
      icon: Icons.wb_twilight,
      children: [
        NightTimeline(report: r, formatTime: _time),
        const SizedBox(height: 4),
        const Text('Bar: sky darkness (darkest = full astro night). Strips: moon up (cream), Milky Way core ≥ 10° (purple).',
            style: TextStyle(fontSize: 11, color: V.textFaint)),
        const SizedBox(height: 12),
        _kv('Sunset', _time(r.sunset)),
        _kv('Civil dusk (−6°)', _time(r.civilDusk)),
        _kv('Nautical dusk (−12°)', _time(r.nauticalDusk)),
        _kv('Astronomical dark (−18°)', r.astroDusk == null ? 'not tonight' : '${_time(r.astroDusk)} – ${_time(r.astroDawn)}'),
        _kv('Nautical dawn', _time(r.nauticalDawn)),
        _kv('Civil dawn', _time(r.civilDawn)),
        _kv('Sunrise', _time(r.sunrise)),
      ],
    );
  }

  Widget _moonCard(NightReport r) {
    final m = r.moon;
    String impact;
    if (m.fraction < 0.15) {
      impact = 'Minimal moonlight: great for the Milky Way and faint objects.';
    } else if (r.moonFreeDarkDuration.inMinutes > 60) {
      impact = 'Shoot while the moon is down for the darkest sky.';
    } else if (m.fraction > 0.7) {
      impact = 'Bright moon: good for moonlit landscapes, poor for the Milky Way.';
    } else {
      impact = 'Moonlight will brighten the sky noticeably.';
    }
    return _card(
      title: 'Moon',
      icon: Icons.nightlight_round,
      children: [
        Row(
          children: [
            MoonIcon(phase: m.phase, size: 64),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  Text('${(m.fraction * 100).round()}% lit · ${m.ageDays.toStringAsFixed(1)} days old'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _kv('Moonrise', _time(r.moonrise)),
        _kv('Moonset', _time(r.moonset)),
        _kv('Next new moon', '${_date(r.nextNewMoon)}, ${_time(r.nextNewMoon)}'),
        _kv('Next full moon', '${_date(r.nextFullMoon)}, ${_time(r.nextFullMoon)}'),
        const SizedBox(height: 8),
        Text(impact, style: const TextStyle(color: V.textDim, fontSize: 13)),
      ],
    );
  }

  Widget _milkyWayCard(NightReport r) {
    final c = r.core;
    String verdict;
    if (c.maxPossibleAltitude < Horizon.coreUseful) {
      verdict = c.maxPossibleAltitude < 0
          ? 'The core never rises at this latitude.'
          : 'The core never gets more than ${c.maxPossibleAltitude.round()}° up here: always low in the haze.';
    } else if (c.visible.isEmpty) {
      verdict = 'Core not visible in darkness tonight. It\'s up during the day this time of year '
          '(the core season is roughly Feb–Oct).';
    } else if (c.best.isEmpty) {
      verdict = 'Core is up in darkness, but so is the moon.';
    } else {
      verdict = 'Core visible with no moon for ${_dur(c.bestDuration)}.';
    }

    String ranges(List<TimeRange> rs) =>
        rs.isEmpty ? 'none' : rs.map((x) => '${_time(x.start)}–${_time(x.end)}').join(', ');

    return _card(
      title: 'Milky Way core',
      icon: Icons.blur_on,
      children: [
        Text(verdict, style: const TextStyle(fontSize: 15)),
        const SizedBox(height: 10),
        _kv('Best (dark, moon down)', ranges(c.best)),
        _kv('Visible in darkness', ranges(c.visible)),
        if (c.highestInDark != null)
          _kv('Highest in darkness',
              '${c.highestAltitude!.round()}° ${c.direction} at ${_time(c.highestInDark)}'),
        _kv('Core rises', _time(c.rise)),
        _kv('Core sets', _time(c.set)),
        const SizedBox(height: 6),
        Text(
          'Galactic centre in Sagittarius. "Visible" means at least ${Horizon.coreUseful.round()}° '
          'above the horizon during full darkness.',
          style: const TextStyle(fontSize: 11, color: V.textFaint),
        ),
      ],
    );
  }

  Widget _cloudCard(NightReport r) {
    final children = <Widget>[];
    if (_forecastError != null && _forecast == null) {
      children.add(Row(children: [
        Expanded(child: Text(_forecastError!, style: const TextStyle(color: V.amber))),
        TextButton(onPressed: () => _loadForecast(force: true), child: const Text('Retry')),
      ]));
    } else if (!r.hasForecast) {
      children.add(Text(_loadingForecast ? 'Loading forecast…' : 'No forecast for this night yet.',
          style: const TextStyle(color: V.textDim)));
    } else {
      if (_forecast?.stale ?? false) {
        children.add(const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('Offline: showing the last saved forecast.',
              style: TextStyle(color: V.amber, fontSize: 12)),
        ));
      }
      children.add(const Padding(
        padding: EdgeInsets.only(bottom: 6),
        child: Row(children: [
          SizedBox(width: 46, child: Text('Time', style: _head)),
          SizedBox(width: 18),
          Expanded(child: Text('Cloud  (low / mid / high)', style: _head)),
          SizedBox(width: 74, child: Text('Temp / dew', style: _head, textAlign: TextAlign.right)),
        ]),
      ));
      for (final h in r.hours) {
        children.add(_hourRow(h));
      }
      children.add(const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('Dot: shooting quality from darkness, clouds and moonlight.',
            style: TextStyle(fontSize: 11, color: V.textFaint)),
      ));
    }
    return _card(title: 'Cloud forecast', icon: Icons.cloud_outlined, children: children);
  }

  static const _head = TextStyle(fontSize: 11, color: V.textDim);

  Widget _hourRow(NightHour h) {
    final w = h.weather;
    final q = h.quality;
    final dot = switch (q) {
      SkyQuality.excellent => const Color(0xFF4CD787),
      SkyQuality.good => const Color(0xFF9BD74C),
      SkyQuality.fair => const Color(0xFFE0B341),
      SkyQuality.poor => const Color(0xFFE05A4C),
      null => Colors.white24,
    };
    final dim = h.darkness == 0;
    return Opacity(
      opacity: dim ? 0.45 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(width: 46, child: Text(_time(h.time), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]))),
            Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            Expanded(
              child: w == null
                  ? const Text('—')
                  : Row(children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: w.cloud / 100,
                            minHeight: 8,
                            backgroundColor: const Color(0xFF0E2A1A),
                            color: V.textDim,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 92,
                        child: Text(
                          ' ${w.cloud}%  ${w.cloudLow ?? '-'}/${w.cloudMid ?? '-'}/${w.cloudHigh ?? '-'}',
                          style: const TextStyle(fontSize: 11, color: V.textDim),
                        ),
                      ),
                    ]),
            ),
            SizedBox(
              width: 74,
              child: Text(
                w?.temperature == null
                    ? ''
                    : '${w!.temperature!.round()}° / ${w.dewPoint?.round() ?? '-'}°',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: (w?.dewRisk ?? false) ? V.amber : V.textDim),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(flex: 3, child: Text(k, style: const TextStyle(color: V.textDim))),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: Text(v, textAlign: TextAlign.right, style: V.readout(16, weight: FontWeight.w400))),
          ],
        ),
      );
}
