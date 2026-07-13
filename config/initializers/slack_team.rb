require Rails.root.join('lib/service/slack_connector')

::Service::SlackConnector.init_team_id
