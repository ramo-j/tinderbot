TinderBot
Tinder trolling bot.

This bot interects with Tinder such that it matches with everyone it can. It then pairs those matches, and for each pair forwards message from one party to the other. Classic MITM.

How do I use it?

1. Set up a fake facebook account. Or use your own, whatever.
2. Go <a href="https://www.facebook.com/dialog/oauth?client_id=464891386855067&redirect_uri=https://www.facebook.com/connect/login_success.html&scope=basic_info,email,public_profile,user_about_me,user_activities,user_birthday,user_education_history,user_friends,user_interests,user_likes,user_location,user_photos,user_relationship_details&response_type=token">here</a> and pull out your authentication token.
3. Create a facebook credential file as below
4. Create a state file as below
5. Run with the command ```tinderBot.pl /path/to/facebookCreds /path/to/state.json```

Facebook Creds File format
```
<authentication token from above>
<15 digit account ID>
```

eg

```
CAAGm0PX4.....tZBwhBh
123456789012345
```

Empty State File Format
```
{}
```

For maximum automation, I recommend running this as a cron job. For every 3 minutes, add the following to /etc/crontab
```
*/3 * * * * user cd /path/to/working/directory; /path/to/tinderBot.pl /path/to/facebookCreds /path/to/state.json
```
