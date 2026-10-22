# frozen_string_literal: true

# Flesch Reading Ease for Brazilian Portuguese (Martins et al., 1996) and English.
module ReadabilityPT
  VERSION = "1.0.0"

  VOWELS = "aeiouáéíóúâêôãõàüy"
  STRONG = "aeoáéóâêôãõà"
  HIGH = "iuíúü"
  STRESS_MARK = "áâéêíóôúãõ"
  NASAL = "ãõ"
  # Unaccented words whose stress falls on a high vowel instead of gliding it.
  # Portuguese spelling does not mark that stress, so it has to be listed.
  HIATUS_WORDS = %w[rainha ainda sair cair raiz juiz ruim].freeze
  PAROXYTONE_ENDING = /(?:[aeo]|em|ens)\z/.freeze

  # Martins et al. (1996) bands for Portuguese.
  BANDS_PT = [[75, "muito fácil"], [50, "fácil"], [25, "difícil"], [0, "muito difícil"]].freeze
  # Flesch (1948) bands for English.
  BANDS_EN = [
    [90, "very easy"], [80, "easy"], [70, "fairly easy"], [60, "standard"],
    [50, "fairly difficult"], [30, "difficult"], [0, "very difficult"]
  ].freeze

  Result = Struct.new(:score, :level, :sentences, :words, :syllables, :avg_words_per_sentence,
                      :avg_syllables_per_word, :long_sentences, keyword_init: true)

  WORD_REGEX = /[[:alpha:]]+(?:[-'’][[:alpha:]]+)*/.freeze
  LONG_SENTENCE = 25

  module_function

  def sentences(text)
    parts = text.split(/(?<=[.!?…])\s+|\n{2,}/).map(&:strip).reject(&:empty?)
    parts.select { |s| s.match?(WORD_REGEX) }
  end

  def words(text)
    text.scan(WORD_REGEX)
  end

  # Heuristic syllable counter for Portuguese: one syllable per vowel group,
  # plus a break inside the group when a high vowel ("i", "u") is a nucleus
  # instead of a glide ("ra-i-nha", "fo-to-gra-fi-a", "sa-í-de", "prai-a").
  # Diphthongs like "ão", "dia" and "cai" stay together.
  def syllables_pt(word)
    # The "u" of "que", "gue", "gui" is silent, not a syllable nucleus.
    w = word.downcase.gsub(/([qg])[uü](?=[ei])/, '\1')
    indices = (0...w.length).select { |i| VOWELS.include?(w[i]) }
    groups = indices.slice_when { |a, b| b != a + 1 }.to_a
    return 1 if groups.empty?

    stress = stressed_vowel(w, groups)
    count = groups.sum do |group|
      1 + group.each_cons(2).count do |i, j|
        a = w[i]
        b = w[j]
        # Two strong vowels in a row are two nuclei: "co-e-lho", "le-ão".
        hiatus = STRONG.include?(a) && STRONG.include?(b) && !NASAL.include?(a)
        # A high vowel that carries the stress is a nucleus, not a glide:
        # "ra-i-nha", "fo-to-gra-fi-a", "sa-í-de".
        hiatus ||= HIGH.include?(b) && j == stress
        hiatus ||= HIGH.include?(a) && i == stress && STRONG.include?(b)
        # An unstressed high vowel that follows another vowel in the same group
        # glides onto it, and the next vowel starts a new syllable:
        # "prai-a", "chei-o", "sa-iu".
        hiatus ||= HIGH.include?(a) && i != group.first && i != stress
        hiatus
      end
    end
    [count, 1].max
  end

  # Index (into w) of the stressed vowel, approximated from accent marks and
  # from the paroxytone/oxytone shape of the word.
  def stressed_vowel(w, groups)
    last = groups.last
    # Nasal diphthongs ("-ão", "-ãe", "-õe") always stress the nasal vowel.
    return last.first if NASAL.include?(w[last.first])
    # An accent mark always shows the stress.
    accented = w.index(/[#{STRESS_MARK}]/)
    return accented if accented
    if HIATUS_WORDS.include?(w)
      high = groups.flat_map { |g| g.drop(1) }.find { |i| HIGH.include?(w[i]) }
      return high if high
    end
    # Unaccented paroxytones ending in a rising pair ("-ia", "-io", "-ua")
    # stress the high vowel: "fo-to-gra-fi-a", "Ma-ri-a", "a-tu-a".
    if groups.size > 1 && last.size == 2 && HIGH.include?(w[last.first]) &&
       STRONG.include?(w[last.last]) && !oxytone?(w)
      return last.first
    end
    # Otherwise the stress falls on the penultimate group, or the last one for
    # oxytones.
    stressed = oxytone?(w) || groups.size == 1 ? groups.last : groups[-2]
    stressed.find { |i| STRONG.include?(w[i]) } || stressed.first
  end

  def oxytone?(w)
    !w.match?(PAROXYTONE_ENDING)
  end
  private_class_method :stressed_vowel, :oxytone?

  # Classic English heuristic: vowel groups, minus a silent final "e".
  def syllables_en(word)
    w = word.downcase.gsub(/[^a-z]/, "")
    return 1 if w.length <= 3

    w = w.sub(/(?:[^laeiouy]es|[^laeiouy]ed|[^laeiouy]e)$/, "").sub(/^y/, "")
    [w.scan(/[aeiouy]+/).size, 1].max
  end

  def analyze(text, lang: :pt)
    lang = lang.to_sym
    raise ArgumentError, "lang must be :pt or :en" unless %i[pt en].include?(lang)

    sentence_list = sentences(text)
    word_list = words(text)
    return nil if word_list.empty?

    syllables = word_list.sum { |w| lang == :pt ? syllables_pt(w) : syllables_en(w) }
    asl = word_list.size.to_f / [sentence_list.size, 1].max
    asw = syllables.to_f / word_list.size
    base = lang == :pt ? 248.835 : 206.835
    score = (base - 1.015 * asl - 84.6 * asw).clamp(0.0, 100.0).round(1)
    level = (lang == :pt ? BANDS_PT : BANDS_EN).find { |min, _label| score >= min }.last

    Result.new(
      score: score,
      level: level,
      sentences: sentence_list.size,
      words: word_list.size,
      syllables: syllables,
      avg_words_per_sentence: asl.round(1),
      avg_syllables_per_word: asw.round(2),
      long_sentences: sentence_list.select { |s| words(s).size > LONG_SENTENCE }
    )
  end
end
