import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/discovery_models.dart';
import 'package:neostation/utils/genre_buckets.dart';

/// Tests for the normalization of scraper genre strings into shelf buckets.
///
/// Two properties matter: compound genres must resolve to their most specific
/// part (`Action-RPG` is an RPG, not an action game), and the six languages
/// ScreenScraper scrapes in must land in the same bucket, because the stored
/// genre is whatever language the user scraped in.
void main() {
  group('genreBucketOf', () {
    test('a plain English genre maps to its bucket', () {
      expect(genreBucketOf('Platform'), GenreBucket.platform);
      expect(genreBucketOf('Shooter'), GenreBucket.shooter);
      expect(genreBucketOf('Fighting'), GenreBucket.fighting);
      expect(genreBucketOf('Racing'), GenreBucket.racing);
      expect(genreBucketOf('Puzzle'), GenreBucket.puzzle);
      expect(genreBucketOf('Sports'), GenreBucket.sports);
      expect(genreBucketOf('Adventure'), GenreBucket.adventure);
      expect(genreBucketOf('Strategy'), GenreBucket.strategy);
      expect(genreBucketOf('Simulation'), GenreBucket.simulation);
      expect(genreBucketOf('Action'), GenreBucket.action);
      expect(genreBucketOf('Arcade'), GenreBucket.action);
      expect(genreBucketOf('Beat \'em Up'), GenreBucket.beatEmUp);
      expect(genreBucketOf('Shoot \'em Up'), GenreBucket.shootEmUp);
      expect(genreBucketOf('Music'), GenreBucket.musicRhythm);
      expect(genreBucketOf('Board & Card'), GenreBucket.boardCard);
      expect(genreBucketOf('Pinball'), GenreBucket.pinball);
      expect(genreBucketOf('Educational'), GenreBucket.educational);
      expect(genreBucketOf('Quiz'), GenreBucket.quiz);
      expect(genreBucketOf('Compilation'), GenreBucket.compilation);
    });

    test('matching is case insensitive', () {
      expect(genreBucketOf('PLATFORM'), GenreBucket.platform);
      expect(genreBucketOf('rpg'), GenreBucket.rpg);
    });

    test('a compound genre takes its first matching part', () {
      expect(genreBucketOf('Platform / Action'), GenreBucket.platform);
      expect(genreBucketOf('Shoot\'em up > Vertical'), GenreBucket.shootEmUp);
      expect(genreBucketOf('Action, Adventure'), GenreBucket.adventure);
    });

    test('a more specific part wins over the generic action part', () {
      // The whole point of the ordered table: `Action-RPG` is an RPG, and a
      // beat 'em up is not just another fighter.
      expect(genreBucketOf('Action-RPG'), GenreBucket.rpg);
      expect(genreBucketOf('Action / Platform'), GenreBucket.platform);
      expect(genreBucketOf('Action|Fighting'), GenreBucket.fighting);
      expect(genreBucketOf('Action / Beat\'em Up'), GenreBucket.beatEmUp);
      expect(genreBucketOf('Action / Shoot\'em Up'), GenreBucket.shootEmUp);
    });

    test('French genre names map like their English equivalents', () {
      expect(genreBucketOf('Jeu de rôle'), GenreBucket.rpg);
      expect(genreBucketOf('Plate-forme'), GenreBucket.platform);
      expect(genreBucketOf('Jeu de tir'), GenreBucket.shooter);
      expect(genreBucketOf('Course'), GenreBucket.racing);
      expect(genreBucketOf('Réflexion'), GenreBucket.puzzle);
      expect(genreBucketOf('Aventure'), GenreBucket.adventure);
      expect(genreBucketOf('Stratégie'), GenreBucket.strategy);
    });

    test('German genre names map like their English equivalents', () {
      expect(genreBucketOf('Rollenspiel'), GenreBucket.rpg);
      expect(genreBucketOf('Plattform'), GenreBucket.platform);
      expect(genreBucketOf('Rennspiel'), GenreBucket.racing);
      expect(genreBucketOf('Rätsel'), GenreBucket.puzzle);
      expect(genreBucketOf('Abenteuer'), GenreBucket.adventure);
      expect(genreBucketOf('Kampfspiel'), GenreBucket.fighting);
    });

    test('Spanish genre names map like their English equivalents', () {
      expect(genreBucketOf('Plataformas'), GenreBucket.platform);
      expect(genreBucketOf('Juego de rol'), GenreBucket.rpg);
      expect(genreBucketOf('Disparos'), GenreBucket.shooter);
      expect(genreBucketOf('Carreras'), GenreBucket.racing);
      expect(genreBucketOf('Rompecabezas'), GenreBucket.puzzle);
      expect(genreBucketOf('Lucha'), GenreBucket.fighting);
      expect(genreBucketOf('Deportes'), GenreBucket.sports);
      expect(genreBucketOf('Aventura'), GenreBucket.adventure);
    });

    test('Italian genre names map like their English equivalents', () {
      expect(genreBucketOf('Piattaforma'), GenreBucket.platform);
      expect(genreBucketOf('Gioco di ruolo'), GenreBucket.rpg);
      expect(genreBucketOf('Sparatutto'), GenreBucket.shooter);
      expect(genreBucketOf('Picchiaduro'), GenreBucket.fighting);
      expect(genreBucketOf('Corsa'), GenreBucket.racing);
      expect(genreBucketOf('Avventura'), GenreBucket.adventure);
    });

    test('Portuguese genre names map like their English equivalents', () {
      expect(genreBucketOf('Plataforma'), GenreBucket.platform);
      expect(genreBucketOf('Corrida'), GenreBucket.racing);
      expect(genreBucketOf('Quebra-cabeça'), GenreBucket.puzzle);
      expect(genreBucketOf('Esportes'), GenreBucket.sports);
      expect(genreBucketOf('Ação'), GenreBucket.action);
    });

    test('null, empty and unknown genres fall in other', () {
      expect(genreBucketOf(null), GenreBucket.other);
      expect(genreBucketOf(''), GenreBucket.other);
      expect(genreBucketOf('   '), GenreBucket.other);
      expect(genreBucketOf('Misc'), GenreBucket.other);
      expect(genreBucketOf('Miscellaneous'), GenreBucket.other);
    });

    test('a keyword only matches at the start of a word', () {
      // `rol` selects the RPG bucket, but must not fire inside `control`.
      expect(genreBucketOf('Controls'), GenreBucket.other);
    });

    test('plural and derived forms match their keyword', () {
      expect(genreBucketOf('Platformer'), GenreBucket.platform);
      expect(genreBucketOf('Shooters'), GenreBucket.shooter);
      expect(genreBucketOf('Sportspiel'), GenreBucket.sports);
    });
  });

  group('genreSlotId', () {
    test('every bucket has a distinct, stable slot id', () {
      final ids = GenreBucket.values.map(genreSlotId).toSet();
      expect(ids.length, GenreBucket.values.length);
      expect(genreSlotId(GenreBucket.rpg), 'genre:rpg');
    });
  });
}
