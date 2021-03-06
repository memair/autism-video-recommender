class User < ApplicationRecord
  before_destroy :revoke_token

  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable,
         :omniauthable, omniauth_providers: [:memair]

  INTERESTS = [
    'Trains & Machines',
    'Science & Technology',
    'Cartoons & Puppets',
    'Songs & Music',
    'Movement & Dance',
    'Crafts & Creative',
    'Maths',
    'Education',
    'Reading',
    'Stories & Riddles',
    'Blogs',
    'News',
    'Environment & Animals',
    'Computer Games'
  ]
  ADMINS = %w( greg@gho.st )

  def admin
    ADMINS.include? self.email
  end

  def self.from_memair_omniauth(omniauth_info)
    data        = omniauth_info.info
    credentials = omniauth_info.credentials

    user = User.where(id: data['id'].to_i).first

    unless user
     user = User.create(
       id:       data['id'].to_i,
       email:    data['email'],
       password: Devise.friendly_token[0,20]
     )
    end

    user.memair_access_token = credentials['token']
    user.save
    user
  end

  def get_recommendations(expires_in: nil, watch_time: self.daily_watch_time, priority: 50)
    expires_at = expires_in.nil? ? DateTime.now.utc + 25.hours : DateTime.now.utc + expires_in.minutes

    videos = preferred_channels.joins(:videos).where.not(videos: {id: previous_recommended.ids}) || recommendable_channels.joins(:videos).where.not(videos: {id: previous_recommended.ids})
    videos = videos.where("videos.duration < ?", watch_time * 60)

    recommendations = []
    duration = 0

    videos.select(:'videos.yt_id', :'videos.title', :'videos.description', :thumbnail_url, :duration, :published_at).order("RANDOM()").limit(100).each do |video|
      break if duration > watch_time * 60
      recommendations.append(
        Recommendation.new(
          yt_id: video.yt_id,
          title: video.title,
          description: video.description,
          thumbnail_url: video.thumbnail_url,
          duration: video.duration,
          published_at: video.published_at,
          priority: priority,
          expires_at: expires_at
        )
      )
      duration += video.duration
    end
    
    recommendations
  end

  def setup?
    !self.functioning_age.nil? && !self.daily_watch_time.nil?
  end

  def recommendable_channels
    Channel.where("#{self.functioning_age} BETWEEN min_age AND max_age")
  end

  def preferred_channels
    if self.interests.empty?
      recommendable_channels
    else
      recommendable_channels.where("'#{self.interests}'::JSONB ?| TRANSLATE(channels.tags::TEXT, '[]','{}')::TEXT[]")
    end
  end

  def previous_recommended
    query = '''
      query {
        Recommendations(
          type: video
          order: desc
          order_by: timestamp
          first: 200
        ){
          url
        }
      }
    '''
    response = Memair.new(self.memair_access_token).query(query)
    yt_ids = response['data']['Recommendations'].map{|r| youtube_id(r['url'])}.compact.uniq
    Video.where(yt_id: yt_ids)
  end

  private
    def revoke_token
      user = Memair.new(self.memair_access_token)
      query = 'mutation {RevokeAccessToken{revoked}}'
      user.query(query)
    end

    def previous_ignored
      query = '''
        query {
          Recommendations(
            type: video
            ignored:true
            order: desc
            order_by: timestamp
            first: 100
          ){
            url
          }
        }
       '''
      response = Memair.new(self.memair_access_token).query(query)
      yt_ids = response['data']['Recommendations'].map{|r| youtube_id(r['url'])}.compact.uniq
      Video.where(yt_id: yt_ids)
    end

    def youtube_id(url)
      regex = /(?:youtube(?:-nocookie)?\.com\/(?:[^\/\n\s]+\/\S+\/|(?:v|e(?:mbed)?)\/|\S*?[?&]v=)|youtu\.be\/)([a-zA-Z0-9_-]{11})/
      matches = regex.match(url)
      matches[1] unless matches.nil?
    end
end
