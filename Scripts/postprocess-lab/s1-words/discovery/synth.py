# Invented dictations with spoken numbers, for finding and testing the edit.
import random, json
random.seed(7)
small = "one two three four five six seven eight nine ten eleven twelve".split()
tens = "twenty thirty forty fifty sixty seventy eighty ninety".split()
def num():
    r = random.random()
    if r < .35: return random.choice(small)
    if r < .6: return random.choice(tens) + (" " + random.choice(small[:9]) if random.random() < .5 else "")
    if r < .75: return random.choice(small[:9]) + " hundred" + (" and " + random.choice(tens) if random.random() < .5 else "")
    if r < .9: return random.choice(small[:9]) + " thousand"
    return random.choice(["a hundred", "a thousand", "a couple of hundred", "half a million"])
nouns = "minutes hours days weeks people tickets units files tests servers boxes chairs emails pages steps rows users".split()
templates = [
 "we need {n} more {x} before friday", "can you book {n} {x} for the team", "it took about {n} {x} to finish",
 "there are {n} {x} left in the queue", "i only had {n} {x} this morning", "send me the {x} by {t} please",
 "lets meet at {t} tomorrow", "the train leaves at {t} so dont be late", "move the call to {t}",
 "set the limit to {n} and restart it", "bump the timeout to {n} seconds", "she said it costs {n} dollars",
 "it was {n} percent faster after the change", "we got {n} replies to the survey", "page {n} has the diagram",
 "i think {n} is too many {x}", "add {n} {x} to the order", "the fix dropped errors by {n} percent",
 "only {n} {x} failed this time", "around {n} {x} signed up yesterday", "he ran {n} miles on sunday",
 "remind me in {n} minutes", "the budget is {n} pounds for the quarter", "give it {n} more {x} and check again",
 "one thing at a time please", "no one replied to the thread", "we picked the second option in the end",
 "i have told you a hundred times", "that was a one off", "first of all thanks for coming",
]
times = ["nine", "ten thirty", "half past two", "quarter to five", "noon", "seven pm", "eight am", "three fifteen", "six oclock"]
out = set()
while len(out) < 260:
    t = random.choice(templates)
    out.add(t.format(n=num(), x=random.choice(nouns), t=random.choice(times)))
out = sorted(out); random.shuffle(out)
json.dump({"train": out[:180], "heldout": out[180:]}, open("synth.json", "w"), indent=1)
print(len(out))
