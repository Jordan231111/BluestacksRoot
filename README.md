# Roots Bluestacks instantly with cmd script


## How to Use

1. Download `blueStackRoot.cmd` `split.cmd`, `rootjunction.cmd`, and `norootjunction.cmd` in [releases](https://github.com/Jordan231111/BluestacksRoot/releases)

2. Launch bluestacks once if you just installed it.

3. Exit all BlueStacks instances or Multi-Instance Manager.

4. Run the `split.cmd` file once (grant admin permissions when prompted). Should delete file after run successfully. **ONLY DO THIS STEP ONCE!**
   
6. Run `rootjunction.cmd` and multiinstance manager should appear.

7. If the following popup appears, click "More info" and then "Run anyway" (Windows blocks ALL .cmd files by default):
Microsoft Defender SmartScreen prevented an unrecognized app from starting

8. create many temporary instances and **DELETE** them afterwards. I recommend 50 to avoid conflicts. Note that you must create and delete more temporary instance than the number of unrooted instances you wish to have. **ONLY DO THIS STEP ONCE!**

9. Label the master instance Do Not Launch and now create the rooted instances. If you want 5, create 5 new instances right now. You can modify it later by creating more.

10. For each instance INDIVIDUALLY install magisk, then run `blueStackRoot.cmd`

11. Wait for the rooting process to complete in the command prompt window. Then install magisk delta to system partition
**Important:** DO NOT unroot until Magisk says it's installed and you get the SU conflict message in the Magisk app.
You must turn off and on the emulator after script has complete **at least confirm you got the SU conflict message** for each instance

12. Go back to script and apply final undo root option. **Only now can you launch multiple Unrooted or Rooted instances at the same time**

13. For convenience, Magisk Kitsune is provided in this repository.

14. To switch to noroot run `norootjunction.cmd` and now you can launch your UnRooted instances, do not modify these or use the tool in here **ALL Modification must be done in `rootjunction.cmd`

## Video tutorial here
[YoutubeLink](https://youtu.be/LOhKGxuhLrU)

## Other Important Information
- Please create a PR for contribution with a clear explanation and images if applicable of the changes and edits
- Report any issues with clear steps to reproduce the issue and a video if possible.
- For BlueStacks instances running Android 11, please use my uploaded Magisk or the Magisk version available at: [https://github.com/HuskyDG/magisk-files/releases/tag/1707294287](https://github.com/HuskyDG/magisk-files/releases/tag/1707294287)

- BlueStacks instances running Android 7 and possibly 9 are only supported by Magisk version 25.2. Please note that using this outdated version is at your own risk, as it may contain unpatched vulnerabilities or compatibility issues. It is highly recommended to upgrade your BlueStacks instance to a newer version of Android for better stability and security.
However, I cannot reproduce the issue and the latest magisk with zygisk is working though u may need to install to system in magisk app twice. Do not undo root until you are satisified it is working
![image](https://github.com/Jordan231111/BluestacksRoot/assets/79342877/7d8da465-2d0c-492d-920b-78bae89828ea)

- You can find such old files [here](https://mega.nz/folder/SQBRHSZQ#pEgMXysWkkTm5Z8dxsNaNQ)
   
- Manual root method my code is mainly based off this method [here](https://xdaforums.com/t/bluestacks-tweaker-6-tool-for-modifing-bluestacks-2-3-3n-4-5.3622681/post-89306676)
- Due to changes that manual method may NOT even work due to hidden services unless manually killed as well so recommend to use this script instead.

## License

This work is licensed under the Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International License. To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-nd/4.0/ or see the [LICENSE](./LICENSE) file.
