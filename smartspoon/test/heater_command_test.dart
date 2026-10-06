import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/devices/domain/heater_command.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';

void main() {
  group('heaterCommandPayload', () {
    test('OFF is exactly three ASCII bytes', () {
      expect(heaterCommandPayload(0), 'OFF');
      expect(heaterCommandPayload(0).codeUnits.length, 3);
    });

    test('ON setpoint is exactly "ON NN" (5 bytes) for firmware grammar', () {
      expect(heaterCommandPayload(40), 'ON 40');
      expect(heaterCommandPayload(40).codeUnits.length, 5);
      expect(heaterCommandPayload(30), 'ON 30');
      expect(heaterCommandPayload(70), 'ON 70');
    });
  });

  group('allowHeaterWrite', () {
    test('sends when the saved record already has a heater', () {
      expect(
        allowHeaterWrite(
          savedHasHeater: true,
          deviceName: 'unknown',
          mcuSubscribed: false,
        ),
        isTrue,
      );
    });

    test('sends when the advertised name contains Pro', () {
      expect(
        allowHeaterWrite(
          savedHasHeater: false,
          deviceName: 'iSpoon Pro',
          mcuSubscribed: false,
        ),
        isTrue,
      );
    });

    test('iSpoon short name is ambiguous, not Basic', () {
      expect(SavedBleDevice.detectHeater('iSpoon'), isFalse);
      expect(SavedBleDevice.isAmbiguousName('iSpoon'), isTrue);
      expect(SavedBleDevice.isAmbiguousName('iSpoon Pro'), isFalse);
      expect(SavedBleDevice.detectHeater('iSpoon Pro'), isTrue);
    });

    test(
      'sends on a live MCU subscription even if the short name is iSpoon',
      () {
        expect(
          allowHeaterWrite(
            savedHasHeater: false,
            deviceName: 'iSpoon',
            mcuSubscribed: true,
          ),
          isTrue,
        );
      },
    );

    test('does not send to an unrelated device with no MCU session', () {
      expect(
        allowHeaterWrite(
          savedHasHeater: false,
          deviceName: 'Heart Rate',
          mcuSubscribed: false,
        ),
        isFalse,
      );
    });
  });

  group('event flags', () {
    test('heater rail bit is 0x20 so Apply can see the spoon ignored ON', () {
      expect(kEvtFlagHeater, 0x20);
      expect(kEvtFlagVbus, 0x01);
      expect(kEvtFlagNtcOk, 0x04);
      expect(eventFlagsHasHeater(0x00), isFalse);
      expect(eventFlagsHasHeater(0x20), isTrue);
      expect(eventFlagsHasVbus(0x01), isTrue);
      expect(eventFlagsHasNtcOk(0x04), isTrue);
    });

    test('heater write bytes are ASCII not UTF-16 code units', () {
      expect(heaterCommandBytes(40), [0x4F, 0x4E, 0x20, 0x34, 0x30]);
      expect(heaterCommandBytes(0), [0x4F, 0x46, 0x46]);
    });

    test('Apply must not pair again — that extra encrypted GATT op drops Android', () {
      expect(
        heaterWriteNeedsEncryptProbe,
        isFalse,
        reason: 'subscribe already starts Just Works; Apply must only WRITE. '
            'Firmware 2.2.20 arms the rail on that write without waiting for L2.',
      );
    });

    test('app must not show heater ON from write echo if the rail is off', () {
      expect(heaterRailShownOn(eventFlags: null, commandedOn: true), isFalse);
      expect(heaterRailShownOn(eventFlags: 0, commandedOn: true), isFalse);
      expect(heaterRailShownOn(eventFlags: kEvtFlagHeater, commandedOn: false), isTrue);
    });

    test('maintain bit 0x40 is the user session, rail 0x20 is the flame', () {
      expect(kEvtFlagHeaterReq, 0x40);
      expect(kHeaterHysteresisC, 5.0);
      expect(eventFlagsHasHeaterReq(0x40), isTrue);
      expect(eventFlagsHasHeaterReq(0x20), isFalse);
    });

    test('recent ON command shows maintain until firmware event arrives', () {
      final t0 = DateTime.utc(2026, 1, 1, 12);
      expect(
        heaterMaintainShown(
          eventFlags: 0,
          commandedOn: true,
          commandedAt: t0,
          now: t0.add(const Duration(seconds: 1)),
        ),
        isTrue,
      );
      expect(
        heaterMaintainShown(
          eventFlags: 0,
          commandedOn: true,
          commandedAt: t0,
          now: t0.add(const Duration(seconds: 4)),
        ),
        isFalse,
      );
      expect(
        heaterMaintainShown(
          eventFlags: kEvtFlagHeaterReq,
          commandedOn: false,
        ),
        isTrue,
      );
    });

    test('UI says Holding when maintain is on and the rail is off', () {
      expect(
        heaterUiPhase(maintainOn: true, railOn: true),
        HeaterUiPhase.heating,
      );
      expect(
        heaterUiPhase(maintainOn: true, railOn: false),
        HeaterUiPhase.holding,
      );
      expect(
        heaterUiStatusLabel(HeaterUiPhase.holding, 40),
        'Holding 40°C',
      );
      expect(
        heaterUiStatusLabel(HeaterUiPhase.heating, 40),
        'Heating to 40°C',
      );
      expect(formatLiveTempC(0, ntcOk: true), '—');
      expect(formatLiveTempC(36.4, ntcOk: true), '36°C');
      expect(formatLiveTempC(36.4, ntcOk: false), '—');
    });
  });
}
