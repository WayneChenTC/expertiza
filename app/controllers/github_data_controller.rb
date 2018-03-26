class GithubDataController < ApplicationController
  class QueryError < StandardError; end

  def action_allowed?
    @submission_record = SubmissionRecord.find(params[:id])
    assignment_team = AssignmentTeam.find(@submission_record.team_id)
    assignment = Assignment.find(assignment_team.parent_id)
    return true if ['Super-Administrator', 'Administrator'].include? current_role_name
    return true if assignment.instructor_id == current_user.id
    return true if TaMapping.exists?(ta_id: current_user.id, course_id: assignment.course_id) && (TaMapping.where(course_id: assignment.course_id).include? TaMapping.where(ta_id: current_user.id, course_id: assignment.course_id).first)
    return true if assignment.course_id && Course.find(assignment.course_id).instructor_id == current_user.id
  end

  # Returns a structured query result or raises Error if the request failed.
  def query(definition, variables = {})
    response = Expertiza::GitHub::Client.query(definition, variables: variables, context: client_context)

    if response.errors.any?
      raise QueryError.new(response.errors[:data].join(", "))
    else
      response.data
    end
  end
  private :query

  # Public: Useful helper method for tracking GraphQL context data to pass
  # along to the network adapter.
  def client_context
    # Use static access token from environment.
    { access_token: Expertiza::GitHub::Application.secrets.github_access_token }
  end
  private :client_context

  IndexQuery = Expertiza::GitHub::Client.parse <<-'GRAPHQL'
    query($owner: String!, $name: String!, $pull: Int!){
      repository(owner: $owner, name: $name) {
        name
        url
        pullRequest(number: $pull) {
          number
          commits(first: 250) {
            totalCount
            nodes {
              commit {
                oid
                committer {
                  name
                }
                committedDate
                additions
                deletions
                message
                changedFiles
              }
            }
          }
        }
      }
    }
  GRAPHQL

  GITHUB_PULL_REGEX = %r(https?:\/\/(?:[w]{3}\.)?github\.com\/([A-Z0-9_\-]+)\/([A-Z0-9_\-]+)\/pull\/([0-9]+)[\S]*)i

  def show
    owner, repo, pull_number = retrieve_github_url(@submission_record)
    assignment = Assignment.find(@submission_record.assignment_id)
    @assignment_start_date = assignment.created_at
    puts "Assignment start: #{@assignment_start_date}"
    @assignment_end_date = @assignment_start_date
    assignment.due_dates.each do |due_date|
      @assignment_end_date = due_date.due_at if due_date.deadline_type.name == "submission" and
          due_date.due_at > @assignment_end_date
    end
    puts "Deadline: #{@assignment_end_date}"
    unless pull_number.nil?
      retrieve_graphql_data(owner, repo, pull_number)
    end
  end

  def retrieve_graphql_data(owner, repo, pull)
    data = query IndexQuery, owner: owner, name: repo, pull: pull.to_i
    github_commits = data.repository.pull_request.commits
    puts "TotalCommits: #{github_commits.total_count}"
    @commits = Array.new
    github_commits.nodes.each do |node|
      @commits.push(node.commit) unless node.commit.message.start_with? "Merge"
      # puts "SHA: #{node.commit.oid}"
      # puts "Name: #{node.commit.committer.name}"
      # puts "Committed Date: #{DateTime.parse(node.commit.committed_date)}"
      # puts "Additions: #{node.commit.additions}"
      # puts "Deletions: #{node.commit.deletions}"
      # puts "Message: #{node.commit.message}"
      # puts "Files changed: #{node.commit.changed_files}",""
    end
    @commits_by_user = Hash.new(0)
    @commits_by_date = Hash.new(0)
    @commits.each do |commit|
      @commits_by_user[commit.committer.name] += 1
      @commits_by_date[DateTime.parse(commit.committed_date).strftime('%Y-%m-%d')] += 1
    end
    puts @commits_by_user
    puts @commits_by_date
  end

  def retrieve_github_url(submission)
    if submission.operation != 'Submit Hyperlink'
      return nil
    end
    matches = GITHUB_PULL_REGEX.match(submission.content)
    return nil if matches.nil?
    matches[1,3]
  end

end