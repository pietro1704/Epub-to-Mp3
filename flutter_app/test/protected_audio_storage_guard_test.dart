import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/protected_audio_storage_guard.dart';

void main() {
  test('accepts protected audio when the reserve remains available', () async {
    final guard = ProtectedAudioStorageGuard(
      availableBytes: () async => 100 * 1024 * 1024,
      reserveBytes: 64 * 1024 * 1024,
    );

    await guard.ensureCanRetain(estimatedBytes: 8 * 1024 * 1024);
  });

  test('reports storage pressure without evicting completed audio', () async {
    final guard = ProtectedAudioStorageGuard(
      availableBytes: () async => 70 * 1024 * 1024,
      reserveBytes: 64 * 1024 * 1024,
    );

    await expectLater(
      guard.ensureCanRetain(estimatedBytes: 8 * 1024 * 1024),
      throwsA(
        isA<ProtectedAudioStorageError>().having(
          (error) => error.requiredBytes,
          'required bytes',
          72 * 1024 * 1024,
        ),
      ),
    );
  });

  test('chapter estimates retain a conservative bounded reserve', () {
    expect(
      ProtectedAudioStorageGuard.estimateChapterAudioBytes('short'),
      8 * 1024 * 1024,
    );
    expect(
      ProtectedAudioStorageGuard.estimateChapterAudioBytes('x' * 100000000),
      128 * 1024 * 1024,
    );
  });
}
