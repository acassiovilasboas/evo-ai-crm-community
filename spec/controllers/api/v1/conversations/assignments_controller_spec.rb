# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe Api::V1::Conversations::AssignmentsController do
    it 'has controller spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Api::V1::Conversations::AssignmentsController, type: :controller do
  let(:conversation) { instance_double(Conversation) }

  before do
    controller.instance_variable_set(:@conversation, conversation)
    # No account association in the Community schema → scopes fall back to .all
    allow(Current).to receive(:account).and_return(nil)
  end

  describe '#set_agent' do
    context 'when assignee_id is blank (legitimate unassign)' do
      before do
        allow(controller).to receive(:params)
          .and_return(ActionController::Parameters.new(assignee_id: ''))
      end

      it 'removes the assignee and responds success' do
        expect(conversation).to receive(:update!).with(assignee: nil)
        expect(controller).to receive(:success_response).with(
          data: {},
          message: 'Agent assignment removed successfully'
        )

        controller.send(:set_agent)
      end
    end

    context 'when assignee_id is present but does NOT resolve to a valid user' do
      before do
        allow(controller).to receive(:params)
          .and_return(ActionController::Parameters.new(assignee_id: 'missing-id'))
        allow(User).to receive(:all).and_return(User)
        allow(User).to receive(:find_by).with(id: 'missing-id').and_return(nil)
      end

      it 'returns a not_found error WITHOUT zeroing the assignee' do
        expect(conversation).not_to receive(:update!)
        expect(controller).to receive(:error_response).with(
          ApiErrorCodes::RESOURCE_NOT_FOUND,
          'Assignee not found or not assignable in this account',
          details: { assignee_id: 'missing-id' },
          status: :not_found
        )

        controller.send(:set_agent)
      end
    end

    context 'when assignee_id resolves to a valid user' do
      let(:agent) { instance_double(User) }

      before do
        allow(controller).to receive(:params)
          .and_return(ActionController::Parameters.new(assignee_id: 'good-id'))
        allow(User).to receive(:all).and_return(User)
        allow(User).to receive(:find_by).with(id: 'good-id').and_return(agent)
        allow(UserSerializer).to receive(:serialize).with(agent).and_return({ id: 'good-id' })
      end

      it 'assigns the agent and responds success' do
        expect(conversation).to receive(:update!).with(assignee: agent)
        expect(controller).to receive(:success_response).with(
          data: { assignee: { id: 'good-id' } },
          message: 'Agent assigned successfully'
        )

        controller.send(:set_agent)
      end
    end
  end

  describe '#set_team' do
    context 'when team_id is blank (legitimate unassign)' do
      before do
        allow(controller).to receive(:params)
          .and_return(ActionController::Parameters.new(team_id: ''))
      end

      it 'removes the team and responds success' do
        expect(conversation).to receive(:update!).with(team: nil)
        expect(controller).to receive(:success_response).with(
          data: { team: nil },
          message: 'Team assignment removed successfully'
        )

        controller.send(:set_team)
      end
    end

    context 'when team_id is present but does NOT resolve to a valid team' do
      before do
        allow(controller).to receive(:params)
          .and_return(ActionController::Parameters.new(team_id: 'missing-id'))
        allow(Team).to receive(:all).and_return(Team)
        allow(Team).to receive(:find_by).with(id: 'missing-id').and_return(nil)
      end

      it 'returns a not_found error WITHOUT zeroing the team' do
        expect(conversation).not_to receive(:update!)
        expect(controller).to receive(:error_response).with(
          ApiErrorCodes::RESOURCE_NOT_FOUND,
          'Team not found or not assignable in this account',
          details: { team_id: 'missing-id' },
          status: :not_found
        )

        controller.send(:set_team)
      end
    end

    context 'when team_id resolves to a valid team' do
      let(:team) { instance_double(Team) }

      before do
        allow(controller).to receive(:params)
          .and_return(ActionController::Parameters.new(team_id: 'good-id'))
        allow(Team).to receive(:all).and_return(Team)
        allow(Team).to receive(:find_by).with(id: 'good-id').and_return(team)
        allow(TeamSerializer).to receive(:serialize).with(team).and_return({ id: 'good-id' })
      end

      it 'assigns the team and responds success' do
        expect(conversation).to receive(:update!).with(team: team)
        expect(controller).to receive(:success_response).with(
          data: { team: { id: 'good-id' } },
          message: 'Team assigned successfully'
        )

        controller.send(:set_team)
      end
    end
  end
end
