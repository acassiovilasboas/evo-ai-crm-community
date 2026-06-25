class Api::V1::Conversations::AssignmentsController < Api::V1::Conversations::BaseController
  # assigns agent/team to a conversation
  def create
    if params.key?(:assignee_id)
      set_agent
    elsif params.key?(:team_id)
      set_team
    else
      error_response(
        ApiErrorCodes::MISSING_REQUIRED_FIELD,
        'Either assignee_id or team_id is required',
        status: :bad_request
      )
    end
  end

  private

  def set_agent
    # Blank assignee_id is a legitimate intent to unassign (remove the agent).
    # A present-but-unresolvable id must NOT silently zero the assignee.
    if params[:assignee_id].blank?
      @conversation.update!(assignee: nil)
      return success_response(
        data: {},
        message: 'Agent assignment removed successfully'
      )
    end

    @agent = assignable_users.find_by(id: params[:assignee_id])

    if @agent.nil?
      return error_response(
        ApiErrorCodes::RESOURCE_NOT_FOUND,
        'Assignee not found or not assignable in this account',
        details: { assignee_id: params[:assignee_id] },
        status: :not_found
      )
    end

    @conversation.update!(assignee: @agent)
    success_response(
      data: { assignee: UserSerializer.serialize(@agent) },
      message: 'Agent assigned successfully'
    )
  end

  def set_team
    # Blank team_id is a legitimate intent to unassign (remove the team).
    # A present-but-unresolvable id must NOT silently zero the team.
    if params[:team_id].blank?
      @conversation.update!(team: nil)
      return success_response(
        data: { team: nil },
        message: 'Team assignment removed successfully'
      )
    end

    @team = assignable_teams.find_by(id: params[:team_id])

    if @team.nil?
      return error_response(
        ApiErrorCodes::RESOURCE_NOT_FOUND,
        'Team not found or not assignable in this account',
        details: { team_id: params[:team_id] },
        status: :not_found
      )
    end

    @conversation.update!(team: @team)
    success_response(
      data: { team: TeamSerializer.serialize(@team) },
      message: 'Team assigned successfully'
    )
  end

  # Scope of users that can be assigned to this conversation.
  # Prefer the account scope when available; otherwise fall back to all users.
  def assignable_users
    Current.account&.users || User.all
  end

  # Scope of teams that can be assigned to this conversation.
  # Prefer the account scope when available; otherwise fall back to all teams.
  def assignable_teams
    Current.account&.teams || Team.all
  end
end
