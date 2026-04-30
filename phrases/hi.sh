#!/bin/bash
# Hindi phrase templates (romanized, matches Kokoro's hf_* / hm_* voices).
# Formal addressing (aap). %s is the repo name.
TEMPLATES_RESPONSE=(
  "%s aapke liye taiyaar hai"
  "%s ko aapke dhyaan ki zaroorat hai"
  "%s mein kaam poora ho gaya"
  "%s aapki samiksha ke liye taiyaar hai"
  "%s mein aapka jawaab chahiye"
  "%s aapke jawaab ka intezaar kar raha hai"
  "%s mein kaam khatam ho gaya"
  "%s mein nateeja taiyaar hai"
  "%s aapke nirdesh ke liye taiyaar hai"
  "%s aapke faisle ka intezaar kar raha hai"
)
TEMPLATES_NOTIFICATION=(
  "%s mein ek faisla chahiye"
  "%s aapke jawaab ka intezaar kar raha hai"
  "%s ko aapke dhyaan ki zaroorat hai"
  "%s mein aapke liye ek sawaal hai"
  "%s manzoori ka intezaar kar raha hai"
  "%s ko aapke nirdesh ki zaroorat hai"
  "%s mein manzoori chahiye"
  "%s aapki samiksha ke liye ruka hua hai"
  "%s mein pushti chahiye"
  "%s input ka intezaar kar raha hai"
)
