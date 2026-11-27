import '../models/custom_sfx.dart';
import '../repositories/custom_sfx_repository.dart';
import 'sfx_service.dart';

class CustomSfxImportService {
  final CustomSfxRepository repository;
  final Future<void> Function(String) validate;
  CustomSfxImportService({
    CustomSfxRepository? repository,
    Future<void> Function(String)? validate,
  }) : repository = repository ?? CustomSfxRepository(),
       validate = validate ?? SfxService().validateClip;

  Future<CustomSfx> import(String path, String filename) async {
    final sound = await repository.stage(path, filename);
    try {
      await validate(await repository.resolve(sound));
      return sound;
    } catch (_) {
      await repository.remove(sound);
      rethrow;
    }
  }
}
