# Fresh Ranks

A small addon for World of Warcraft: Forever that keeps your action bars up to date when you learn spells, like the modern game does.

## What it does

- **New rank of a spell you already use:** when you train a higher rank (for example Frostbolt Rank 4), every action bar button that held your previous best rank (Rank 3) now gets Rank 4.
- **Lower ranks stay:** if you put an older rank on a bar on purpose (for example Rank 1 to save mana), it is left alone.
- **Brand-new spell:** when you learn a spell you did not have before, it is put in the first empty slot of your main action bar. If that bar is full, it goes to the next action bar that is turned on.
- **Nothing else is touched:** macros, items, mounts and other spells on your bars are never moved, replaced or removed.

A short line in chat tells you what changed, for example:

```
Fresh Ranks: Frostbolt (Rank 4) is now on 2 action buttons.
Fresh Ranks: Arcane Missiles added to action bar 1.
```

## Good to know

- **In combat:** action bars cannot be changed during combat. Fresh Ranks waits and updates your bars as soon as combat ends.
- **Holding something on your mouse:** it waits until your mouse cursor is empty, so it never drops what you are dragging.
- **No free slot:** if all your shown bars are full, nothing is changed and chat tells you to drag the spell from your spellbook (press P).
- **Passive spells and profession spells** (like Find Herbs) are not placed on your bars.
- **Spells you already have when you log in** are not touched. Fresh Ranks only reacts to spells you learn while it is running.
- **Controller mode** uses its own bars, which Fresh Ranks does not change.
- There are no settings and no slash commands. Install it and it just works.

## Install

1. Close World of Warcraft.
2. Unzip `FreshRanks.zip` into `World of Warcraft\_forever_\Interface\AddOns\` so that you get the folder `AddOns\FreshRanks` with `FreshRanks.toc` inside it.
3. Start the game. On the character screen, click **AddOns** and make sure **Fresh Ranks** is ticked.

## Try it

1. Put a spell on your bar (for example your main attack spell).
2. Visit your class trainer and train its next rank.
3. Close the trainer and look at your bar: the button now shows the new rank (hover over it to see the rank in the tooltip), and chat shows a Fresh Ranks line.
